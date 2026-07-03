#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NodeSeek 论坛自动签到工具
- 支持 Cookie 或 账号密码登录
- 账号密码登录通过 SeleniumBase UC 模式自动求解 Cloudflare Turnstile 验证码（免费，无需打码平台）
- 签到请求通过 curl_cffi 浏览器指纹模拟绕过 Cloudflare TLS 校验
- 支持 Telegram 通知
- 自动更新 Cookie 并保存至 GitHub Actions 变量
- 支持多账号、随机签到模式
- 适配 GitHub Actions 定时运行 / 青龙面板 / 本地运行
"""

import os
import sys
import time
import random
import logging
from curl_cffi import requests

# ==================== 常量配置 ====================
NODESEEK_BASE = "https://www.nodeseek.com"
ATTENDANCE_API = f"{NODESEEK_BASE}/api/attendance"
LOGIN_API = f"{NODESEEK_BASE}/api/account/signIn"
LOGIN_PAGE = f"{NODESEEK_BASE}/signIn.html"
BOARD_PAGE = f"{NODESEEK_BASE}/board"

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0"
)

# ==================== 日志配置 ====================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("nodeseek")


# ==================== 工具函数 ====================
def get_env(name, default=""):
    """读取环境变量，去除首尾空白"""
    val = os.environ.get(name, "")
    return val.strip() if val else default


def parse_multi(value):
    """将用 & 分隔的多值字符串拆分为列表"""
    if not value:
        return []
    return [v.strip() for v in value.split("&") if v.strip()]


# ==================== Telegram 通知 ====================
def send_telegram(message):
    """发送 Telegram 通知"""
    token = get_env("TG_BOT_TOKEN")
    chat_id = get_env("TG_CHAT_ID")
    if not token or not chat_id:
        log.warning("Telegram 配置不完整，跳过通知")
        return False

    api_url = get_env("TG_API_URL", "https://api.telegram.org")
    url = f"{api_url}/bot{token}/sendMessage"
    try:
        resp = requests.post(
            url,
            json={"chat_id": chat_id, "text": message, "parse_mode": "HTML"},
            timeout=30,
        )
        if resp.status_code == 200:
            log.info("Telegram 通知发送成功")
            return True
        log.error(f"Telegram 通知发送失败: {resp.status_code} {resp.text}")
        return False
    except Exception as e:
        log.error(f"Telegram 通知发送异常: {e}")
        return False


# ==================== 账号密码登录（SeleniumBase UC 模式求解 Turnstile）====================
def _enrich_proxy_auth(proxy_url):
    """
    如果代理是 SOCKS 类型且未包含认证信息，从 NS_PROXY_USER / NS_PROXY_PASS 环境变量补充
    支持格式: socks5://user:pass@host:port, socks5h://user:pass@host:port
    """
    if not proxy_url:
        return proxy_url

    # 已经包含认证信息（@ 在 host:port 之前）
    if "@" in proxy_url:
        return proxy_url

    # 仅对 socks 代理补充认证
    lower = proxy_url.lower()
    if not (lower.startswith("socks5") or lower.startswith("socks4")):
        return proxy_url

    user = get_env("NS_PROXY_USER", "")
    passwd = get_env("NS_PROXY_PASS", "")
    if not user:
        return proxy_url

    # 解析 scheme://host:port
    if "://" in proxy_url:
        scheme, rest = proxy_url.split("://", 1)
        return f"{scheme}://{user}:{passwd}@{rest}"
    else:
        # 无 scheme 的情况（不太可能但做防御）
        return f"socks5://{user}:{passwd}@{proxy_url}"


def _detect_system_proxy():
    """自动检测系统代理设置（Windows），自动为 SOCKS 代理补充用户名密码"""
    # 1. 环境变量 NS_PROXY 优先
    proxy = get_env("NS_PROXY", "")
    if proxy:
        return _enrich_proxy_auth(proxy)

    # 2. 检测常见的系统代理环境变量
    for var in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        val = os.environ.get(var, "")
        if val and val.strip():
            return _enrich_proxy_auth(val.strip())

    # 3. Windows: 从注册表读取系统代理设置
    if sys.platform == "win32":
        try:
            import winreg
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            )
            proxy_enable, _ = winreg.QueryValueEx(key, "ProxyEnable")
            if proxy_enable:
                proxy_server, _ = winreg.QueryValueEx(key, "ProxyServer")
                winreg.CloseKey(key)
                if proxy_server:
                    if "=" in proxy_server:
                        for part in proxy_server.split(";"):
                            if part.startswith("http=") or part.startswith("https="):
                                addr = part.split("=", 1)[1]
                                if not addr.startswith("http"):
                                    addr = "http://" + addr
                                return _enrich_proxy_auth(addr)
                    else:
                        if not proxy_server.startswith("http"):
                            proxy_server = "http://" + proxy_server
                        return _enrich_proxy_auth(proxy_server)
            winreg.CloseKey(key)
        except Exception:
            pass

    return ""


def _test_proxy_for_cloudflare(proxy_url):
    """测试代理是否能访问 challenges.cloudflare.com，自动检测代理类型"""
    import urllib.request

    # 解析代理地址和端口
    if "://" in proxy_url:
        scheme, rest = proxy_url.split("://", 1)
    else:
        scheme = ""
        rest = proxy_url

    # 要测试的代理格式列表（socks5 优先，V2Ray/Xray 常用 socks5 端口）
    if scheme:
        candidates = [proxy_url]
    else:
        candidates = [
            f"socks5://{rest}",
            f"http://{rest}",
        ]

    for candidate in candidates:
        try:
            proxy_handler = urllib.request.ProxyHandler({
                "http": candidate,
                "https": candidate,
            })
            opener = urllib.request.build_opener(proxy_handler)
            req = urllib.request.Request(
                "https://challenges.cloudflare.com/turnstile/v0/api.js",
                headers={"User-Agent": DEFAULT_UA},
            )
            resp = opener.open(req, timeout=10)
            if resp.status == 200:
                return candidate
        except Exception:
            continue

    return None


def login_with_credentials(username, password, random_mode="true"):
    """
    使用账号密码登录 NodeSeek，返回 Cookie 字符串
    通过 SeleniumBase UC 模式（undetected-chromedriver）启动浏览器，
    让 Cloudflare Turnstile 在真实 Chrome 环境中自动求解，然后执行登录。
    无需任何第三方打码平台，完全免费。
    """
    try:
        from seleniumbase import Driver
    except ImportError:
        log.error("seleniumbase 未安装，无法使用账号密码登录")
        log.error("请执行: pip install seleniumbase")
        return None

    headless = get_env("NS_HEADLESS", "true") != "false"
    raw_proxy = _detect_system_proxy()

    # 测试代理是否能访问 challenges.cloudflare.com
    proxy_url = ""
    if raw_proxy:
        log.info(f"检测到系统代理: {raw_proxy}，测试连通性...")
        proxy_url = _test_proxy_for_cloudflare(raw_proxy)
        if proxy_url:
            log.info(f"代理测试通过: {proxy_url}")
        else:
            log.warning(f"代理 {raw_proxy} 无法访问 challenges.cloudflare.com，尝试不带代理运行...")

    log.info(f"正在使用浏览器登录: {username}（headless={headless}, proxy={'已设置: ' + proxy_url if proxy_url else '无'}）")

    # 构建 SeleniumBase Driver 参数
    driver_kwargs = {
        "uc": True,  # undetected-chromedriver 模式
        "headless": headless,
        "locale_code": "zh-CN",
    }
    if proxy_url:
        # SeleniumBase 代理参数格式: "host:port" 或带协议
        driver_kwargs["proxy"] = proxy_url

    driver = None
    try:
        driver = Driver(**driver_kwargs)
        driver.maximize_window()
        # 设置异步脚本超时（execute_async_script 等待 callback 的最长时间）
        driver.set_script_timeout(30)

        # 1. 访问登录页
        log.info("访问登录页...")
        driver.uc_open_with_reconnect(LOGIN_PAGE, reconnect_time=4)
        time.sleep(3)

        # 2. 检查 turnstile 全局对象是否就绪，如果就绪但 widget 未渲染则手动渲染
        log.info("检查 Turnstile 全局对象...")
        time.sleep(2)
        turnstile_ready = driver.execute_script(
            """return typeof turnstile !== 'undefined' && typeof turnstile.render === 'function';"""
        )
        if turnstile_ready:
            # 检查是否已有 widget
            has_widget = driver.execute_script(
                """return !!(document.querySelector('iframe[src*="challenges.cloudflare.com"]') || document.querySelector('.cf-turnstile'));"""
            )
            if not has_widget:
                log.info("Turnstile 全局对象已就绪但 widget 未渲染，手动调用 turnstile.render()...")
                # 查找或创建容器
                driver.execute_script(
                    """(function() {
                        // 查找 NodeSeek 的 Turnstile 容器
                        var container = document.querySelector('[data-sitekey]')
                                    || document.querySelector('.cf-turnstile')
                                    || document.querySelector('#turnstile-container')
                                    || document.querySelector('[id*="turnstile"]');
                        if (!container) {
                            // 创建一个新容器
                            container = document.createElement('div');
                            container.id = 'ns-turnstile-container';
                            // 插入到登录表单附近
                            var form = document.querySelector('form') || document.body;
                            form.parentNode.insertBefore(container, form.nextSibling);
                        }
                        // 获取 sitekey
                        var sitekey = container.getAttribute('data-sitekey') || '0x4AAAAAAAaNy7leGjewpVyR';
                        // 调用 turnstile.render
                        try {
                            turnstile.render(container, {
                                sitekey: sitekey,
                                callback: function(token) {
                                    var el = document.querySelector('[name="cf-turnstile-response"]');
                                    if (!el) {
                                        el = document.createElement('input');
                                        el.type = 'hidden';
                                        el.name = 'cf-turnstile-response';
                                        document.body.appendChild(el);
                                    }
                                    el.value = token;
                                }
                            });
                            window._ns_turnstile_rendered = true;
                        } catch(e) {
                            window._ns_turnstile_error = e.toString();
                        }
                    })();"""
                )
                # 检查渲染结果
                render_result = driver.execute_script(
                    """return { rendered: window._ns_turnstile_rendered || false, error: window._ns_turnstile_error || null };"""
                )
                if render_result.get("error"):
                    log.error(f"turnstile.render() 出错: {render_result['error']}")
                elif render_result.get("rendered"):
                    log.info("Turnstile widget 手动渲染成功，等待求解...")
                time.sleep(2)

        # 3. 等待 Turnstile 求解
        log.info("等待 Turnstile 验证码自动求解...")
        token = None
        for i in range(30):  # 最多等待 30 秒
            time.sleep(1)
            token = driver.execute_script(
                """return (function() {
                    var el = document.querySelector('[name="cf-turnstile-response"]');
                    if (el && el.value && el.value.length > 10) return el.value;
                    var widget = document.querySelector('.cf-turnstile');
                    if (widget) {
                        var r = widget.getAttribute('data-response');
                        if (r && r.length > 10) return r;
                    }
                    return null;
                })();"""
            )
            if token:
                log.info(f"Turnstile 验证码求解成功 (等待 {i+1}s)")
                break

            # 每 10 秒打印调试状态
            if (i + 1) % 10 == 0:
                debug = driver.execute_script(
                    """return (function() {
                        var iframes = Array.from(document.querySelectorAll('iframe'));
                        var cfIframe = document.querySelector('iframe[src*="challenges.cloudflare.com"]');
                        var turnstileDiv = document.querySelector('.cf-turnstile');
                        var turnstileInput = document.querySelector('[name="cf-turnstile-response"]');
                        var hasTurnstile = typeof turnstile !== 'undefined';
                        return {
                            iframeCount: iframes.length,
                            iframeSrcs: iframes.map(f => f.src ? f.src.substring(0, 60) : '(empty)'),
                            hasCfIframe: !!cfIframe,
                            hasTurnstileDiv: !!turnstileDiv,
                            turnstileInputValue: turnstileInput ? turnstileInput.value.substring(0, 20) : null,
                            turnstileDefined: hasTurnstile,
                            rendered: window._ns_turnstile_rendered || false
                        };
                    })();"""
                )
                log.info(f"仍在等待... ({i+1}s) iframes={debug.get('iframeCount')}, cfIframe={debug.get('hasCfIframe')}, turnstileDiv={debug.get('hasTurnstileDiv')}, turnstileDefined={debug.get('turnstileDefined')}, rendered={debug.get('rendered')}, inputVal={debug.get('turnstileInputValue')}")

        # 如果自动求解失败，尝试通过 JS 点击 Turnstile checkbox
        if not token:
            log.info("Turnstile 未自动求解，尝试 JS 点击 checkbox...")
            for attempt in range(3):
                try:
                    # 用 JS 直接在页面操作，绕过 Selenium 的 iframe 限制
                    clicked = driver.execute_script(
                        """return (function() {
                            var iframe = document.querySelector('iframe[src*="challenges.cloudflare.com"]')
                                || document.querySelector('iframe[title*="Cloudflare"]')
                                || document.querySelector('iframe[title*="Widget"]');
                            if (!iframe) {
                                // 检查是否有 shadow DOM 或其他容器
                                var container = document.querySelector('[data-sitekey]') || document.querySelector('.cf-turnstile');
                                if (container) {
                                    container.click();
                                    return 'clicked_container';
                                }
                                return 'no_iframe_no_container';
                            }
                            // 获取 iframe 位置并点击
                            var rect = iframe.getBoundingClientRect();
                            var x = rect.left + 28;
                            var y = rect.top + rect.height / 2;
                            // 模拟真实点击
                            var evt = new MouseEvent('click', {
                                bubbles: true,
                                cancelable: true,
                                clientX: x,
                                clientY: y
                            });
                            iframe.dispatchEvent(evt);
                            // 也尝试点击 iframe 父容器
                            if (iframe.parentElement) {
                                iframe.parentElement.click();
                            }
                            return 'clicked_iframe_' + x + '_' + y;
                        })();"""
                    )
                    log.info(f"JS 点击 Turnstile (第 {attempt + 1} 次): {clicked}")
                    time.sleep(3)

                    # 检查 token
                    token = driver.execute_script(
                        """return (function() {
                            var el = document.querySelector('[name="cf-turnstile-response"]');
                            if (el && el.value && el.value.length > 10) return el.value;
                            var widget = document.querySelector('.cf-turnstile');
                            if (widget) {
                                var r = widget.getAttribute('data-response');
                                if (r && r.length > 10) return r;
                            }
                            return null;
                        })();"""
                    )
                    if token:
                        log.info(f"Turnstile 验证码求解成功 (JS 点击后)")
                        break

                    # 也尝试用 ActionChains 点击 iframe 位置
                    if not token:
                        try:
                            iframe_el = driver.execute_script(
                                """return document.querySelector('iframe[src*="challenges.cloudflare.com"]');"""
                            )
                            if iframe_el:
                                from selenium.webdriver import ActionChains
                                actions = ActionChains(driver)
                                actions.move_to_element_with_offset(iframe_el, 28, 0)
                                actions.click()
                                actions.perform()
                                log.info(f"ActionChains 点击 iframe (第 {attempt + 1} 次)")
                                time.sleep(3)
                                token = driver.execute_script(
                                    """return (function() {
                                        var el = document.querySelector('[name="cf-turnstile-response"]');
                                        if (el && el.value && el.value.length > 10) return el.value;
                                        return null;
                                    })();"""
                                )
                                if token:
                                    log.info(f"Turnstile 验证码求解成功 (ActionChains 点击后)")
                                    break
                        except Exception as e:
                            log.warning(f"ActionChains 点击失败: {e}")
                except Exception as e:
                    log.warning(f"JS 点击 Turnstile 第 {attempt + 1} 次失败: {e}")
                    time.sleep(2)

        if not token:
            log.error("Turnstile 验证码求解超时，登录失败")
            try:
                driver.save_screenshot_to_logs("debug_turnstile_timeout.png")
                log.info("已保存超时截图")
            except Exception:
                pass
            driver.quit()
            return None

        # 4. 在浏览器内调用登录 API（必须用 execute_async_script 等待 fetch 完成）
        log.info("调用登录接口...")
        result = driver.execute_async_script(
            """const callback = arguments[arguments.length - 1];
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 25000);
            fetch(arguments[0], {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Captcha-Token': arguments[3],
                    'X-Captcha-Source': 'turnstile'
                },
                body: JSON.stringify({
                    username: arguments[1],
                    password: arguments[2]
                }),
                signal: controller.signal
            })
            .then(r => r.text().then(text => {
                clearTimeout(timeoutId);
                let data;
                try { data = JSON.parse(text); }
                catch(e) {
                    return callback({
                        success: false,
                        message: '响应非JSON (HTTP ' + r.status + '): ' + text.substring(0, 200),
                        _status: r.status,
                        _raw: text.substring(0, 500)
                    });
                }
                data._status = r.status;
                callback(data);
            }))
            .catch(e => {
                clearTimeout(timeoutId);
                callback({ success: false, message: 'fetch错误: ' + e.toString() });
            });""",
            LOGIN_API,
            username,
            password,
            token,
        )

        if result and result.get("success"):
            # 5. 导航到主页，等待 Cloudflare 验证通过后用 CDP Fetch 签到
            driver.get(BOARD_PAGE)
            log.info("等待 Cloudflare 验证通过...")
            for i in range(15):
                time.sleep(2)
                title = driver.title or ""
                if "just a moment" not in title.lower() and "checking" not in title.lower():
                    log.info(f"页面加载完成: {title}")
                    break
            else:
                log.warning("Cloudflare 验证可能未通过")
            # 6. 签到：完全复刻 NodeSeek X 官方签到逻辑
            # net.post('/api/attendance?random=true') => fetch(url, { method:'POST', credentials:'include' })
            try:
                sign_result = driver.execute_async_script(
                    """const callback = arguments[arguments.length - 1];
                    fetch(arguments[0], {
                        method: 'POST',
                        credentials: 'include'
                    })
                    .then(r => r.json().then(data => {
                        data._status = r.status;
                        callback(data);
                    }))
                    .catch(e => {
                        callback({ success: false, message: 'fetch错误: ' + e.toString() });
                    });""",
                    f"{ATTENDANCE_API}?random={random_mode}",
                )
            except Exception as e:
                log.warning(f"浏览器签到异常: {e}")
                sign_result = {"success": False, "message": str(e)}
            log.info(f"浏览器内签到结果: {sign_result}")
            # 7. 提取浏览器 Cookie（包含 cf_clearance）
            cookies = driver.get_cookies()
            cookie_str = "; ".join(f"{c['name']}={c['value']}" for c in cookies)
            driver.quit()
            log.info("账号密码登录成功")
            return cookie_str, sign_result
        else:
            msg = result.get("message", "未知错误") if result else "无响应"
            status_code = result.get("_status") if result else None
            log.error(f"登录失败: {msg}" + (f" (HTTP {status_code})" if status_code else ""))
            driver.quit()
            return None, None

    except Exception as e:
        log.error(f"浏览器登录异常: {e}")
        if driver:
            try:
                driver.quit()
            except Exception:
                pass
        return None, None


# ==================== 签到 ====================
def sign_in(cookie, random_mode="true", proxy=""):
    """
    执行签到操作
    :param cookie: NodeSeek Cookie 字符串
    :param random_mode: "true"=随机签到(1~N鸡腿), "false"=固定签到(鸡腿x5)
    :param proxy: 代理地址（可选）
    :return: (status, message) status: success/already/invalid/fail/error
    """
    headers = {
        "User-Agent": DEFAULT_UA,
        "Origin": NODESEEK_BASE,
        "Referer": BOARD_PAGE,
        "Cookie": cookie,
    }
    url = f"{ATTENDANCE_API}?random={random_mode}"

    try:
        kwargs = dict(headers=headers, impersonate="chrome", timeout=30)
        if proxy:
            kwargs["proxy"] = proxy
        log.info(f"签到请求: POST {url}, random={random_mode}, proxy={'有' if proxy else '无'}")
        resp = requests.post(url, **kwargs)
        log.info(f"签到响应: HTTP {resp.status_code}")
        # Cloudflare 拦截：POST 被降级为 GET
        if resp.status_code == 404 and "Cannot GET" in resp.text:
            log.error("Cloudflare 拦截：POST 请求被转为 GET")
            return "error", "Cloudflare 拦截: POST 被转为 GET"
        try:
            data = resp.json()
        except Exception:
            log.error(f"签到请求返回非JSON (HTTP {resp.status_code}): {resp.text[:200]}")
            return "error", f"HTTP {resp.status_code}: 响应非JSON"
        message = data.get("message", "")
        success = data.get("success", False)

        if success or "鸡腿" in message:
            return "success", message
        elif "已完成签到" in message:
            return "already", message
        elif resp.status_code == 404 or "NOT FOUND" in message.upper() or "USER NOT FOUND" in message.upper():
            return "invalid", message
        else:
            return "fail", message
    except Exception as e:
        return "error", str(e)


# ==================== GitHub Secret 更新 ====================
def save_cookie_to_github(cookie_str):
    """
    将 Cookie 保存到 GitHub Actions 仓库 Secret
    需要 GH_PAT (有 repo 权限) 和 GITHUB_REPOSITORY 环境变量
    """
    token = get_env("GH_PAT")
    repo = os.environ.get("GITHUB_REPOSITORY", "")

    if not token or not repo:
        log.warning("GH_PAT 或 GITHUB_REPOSITORY 未设置，跳过 GitHub Secret 更新")
        return False

    # 用 libsodium 加密 secret（GitHub API 要求）
    import base64
    try:
        from nacl import public
    except ImportError:
        log.warning("pynacl 未安装，无法加密 Secret，跳过更新。pip install pynacl")
        return False

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }

    secret_name = "NS_COOKIE"

    # 1. 获取仓库公钥
    key_url = f"https://api.github.com/repos/{repo}/actions/secrets/public-key"
    resp = requests.get(key_url, headers=headers, timeout=30)
    if resp.status_code != 200:
        log.error(f"获取仓库公钥失败: {resp.status_code} {resp.text}")
        return False

    key_data = resp.json()
    public_key = public.PublicKey(base64.b64decode(key_data["key"]))
    key_id = key_data["key_id"]

    # 2. 加密 secret 值
    sealed_box = public.SealedBox(public_key)
    encrypted = sealed_box.encrypt(cookie_str.encode("utf-8"))
    encrypted_b64 = base64.b64encode(encrypted).decode("utf-8")

    # 3. 创建或更新 secret
    secret_url = f"https://api.github.com/repos/{repo}/actions/secrets/{secret_name}"
    resp = requests.put(
        secret_url,
        headers=headers,
        json={"encrypted_value": encrypted_b64, "key_id": key_id},
        timeout=30,
    )
    if resp.status_code in (201, 204):
        log.info(f"GitHub Secret {secret_name} 更新成功")
        return True
    log.error(f"GitHub Secret 更新失败: {resp.status_code} {resp.text}")
    return False


# ==================== 主流程 ====================
def main():
    log.info("=" * 50)
    log.info("NodeSeek 论坛自动签到")
    log.info("=" * 50)

    # 读取配置
    ns_random = get_env("NS_RANDOM", "true")  # 默认随机签到
    cookie_env = get_env("NS_COOKIE")
    username_env = get_env("NS_USERNAME")
    password_env = get_env("NS_PASSWORD")

    # 多账号: 用 & 分隔
    cookies = parse_multi(cookie_env)
    usernames = parse_multi(username_env)
    passwords = parse_multi(password_env)

    max_len = max(len(cookies), len(usernames), len(passwords))
    if max_len == 0:
        log.error("未配置任何账号信息，请设置 NS_COOKIE 或 NS_USERNAME + NS_PASSWORD")
        return

    # 合并账号信息
    accounts = []
    for i in range(max_len):
        accounts.append({
            "cookie": cookies[i] if i < len(cookies) else "",
            "username": usernames[i] if i < len(usernames) else "",
            "password": passwords[i] if i < len(passwords) else "",
        })

    log.info(f"共 {len(accounts)} 个账号，签到模式: {'随机' if ns_random == 'true' else '固定'}")

    # 随机延迟，模拟非准时签到
    delay_str = get_env("NS_DELAY", "")
    if delay_str:
        parts = delay_str.split("-")
        if len(parts) == 2:
            lo, hi = int(parts[0]), int(parts[1])
            delay = random.randint(lo, hi)
        else:
            delay = int(delay_str)
        log.info(f"随机延迟 {delay} 秒后开始签到...")
        time.sleep(delay)
    else:
        # 默认随机延迟 0~300 秒
        delay = random.randint(0, 300)
        if delay > 0:
            log.info(f"随机延迟 {delay} 秒后开始签到...")
            time.sleep(delay)

    results = []
    updated_cookies = []
    cookie_changed = False

    # 检测代理（签到请求也需要代理才能访问 nodeseek.com）
    sign_proxy = ""
    raw_proxy = _detect_system_proxy()
    if raw_proxy:
        sign_proxy = _test_proxy_for_cloudflare(raw_proxy) or ""

    for idx, acc in enumerate(accounts):
        log.info(f"\n--- 账号 {idx + 1}/{len(accounts)} ---")

        # 账号间随机延迟
        if idx > 0:
            gap = random.randint(10, 60)
            log.info(f"等待 {gap} 秒...")
            time.sleep(gap)

        cookie = acc["cookie"]

        # 如果没有 Cookie 但有账号密码，尝试登录并在浏览器内签到
        if not cookie and acc["username"] and acc["password"]:
            log.info("无 Cookie，使用账号密码登录...")
            login_result = login_with_credentials(acc["username"], acc["password"], ns_random)
            if not login_result or not login_result[0]:
                results.append(f"账号{idx + 1}: 登录失败")
                continue
            cookie = login_result[0]
            browser_sign = login_result[1]
            updated_cookies.append(cookie)
            cookie_changed = True

            # 使用浏览器内签到结果
            if browser_sign and browser_sign.get("success"):
                msg = browser_sign.get("message", "签到成功")
                log.info(f"签到成功: {msg}")
                results.append(f"账号{idx + 1}: 签到成功 - {msg}")
            elif browser_sign and "已完成签到" in browser_sign.get("message", ""):
                msg = browser_sign.get("message", "今日已签到")
                log.info(f"今日已签到: {msg}")
                results.append(f"账号{idx + 1}: 今日已签到 - {msg}")
            elif browser_sign:
                msg = browser_sign.get("message", "签到失败")
                log.warning(f"浏览器签到失败: {msg}，尝试 curl_cffi 签到...")
                status, message = sign_in(cookie, ns_random, sign_proxy)
                if status == "success":
                    results.append(f"账号{idx + 1}: 签到成功 - {message}")
                elif status == "already":
                    results.append(f"账号{idx + 1}: 今日已签到 - {message}")
                else:
                    results.append(f"账号{idx + 1}: 签到失败 - {message}")
            else:
                log.error("浏览器签到无响应，尝试 curl_cffi 签到...")
                status, message = sign_in(cookie, ns_random, sign_proxy)
                if status == "success":
                    results.append(f"账号{idx + 1}: 签到成功 - {message}")
                elif status == "already":
                    results.append(f"账号{idx + 1}: 今日已签到 - {message}")
                else:
                    results.append(f"账号{idx + 1}: 签到失败 - {message}")
            continue
        elif not cookie:
            results.append(f"账号{idx + 1}: 无 Cookie 且无账号密码配置")
            continue
        else:
            updated_cookies.append(cookie)

        # 执行签到
        status, message = sign_in(cookie, ns_random, sign_proxy)

        if status == "success":
            log.info(f"签到成功: {message}")
            results.append(f"账号{idx + 1}: 签到成功 - {message}")
        elif status == "already":
            log.info(f"今日已签到: {message}")
            results.append(f"账号{idx + 1}: 今日已签到 - {message}")
        elif status == "invalid":
            log.warning(f"Cookie 失效: {message}")
            # Cookie 失效时尝试重新登录
            if acc["username"] and acc["password"]:
                log.info("Cookie 失效，尝试重新登录...")
                login_result = login_with_credentials(acc["username"], acc["password"], ns_random)
                if login_result and login_result[0]:
                    new_cookie = login_result[0]
                    browser_sign = login_result[1]
                    updated_cookies[-1] = new_cookie
                    cookie_changed = True
                    if browser_sign and browser_sign.get("success"):
                        results.append(f"账号{idx + 1}: 重新登录后签到成功 - {browser_sign.get('message', '')}")
                    elif browser_sign and "已完成签到" in browser_sign.get("message", ""):
                        results.append(f"账号{idx + 1}: 重新登录后今日已签到 - {browser_sign.get('message', '')}")
                    else:
                        results.append(f"账号{idx + 1}: 重新登录后签到失败 - {browser_sign.get('message', '未知') if browser_sign else '无响应'}")
                else:
                    results.append(f"账号{idx + 1}: Cookie 失效且重新登录失败")
            else:
                results.append(f"账号{idx + 1}: Cookie 失效 - {message}")
        else:
            log.error(f"签到失败: {message}")
            results.append(f"账号{idx + 1}: 签到失败 - {message}")

    # 更新 GitHub 变量
    if cookie_changed and updated_cookies:
        combined = "&".join(updated_cookies)
        log.info("检测到 Cookie 变更，更新 GitHub 变量...")
        save_cookie_to_github(combined)

    # 发送 Telegram 通知
    report = "\n".join(results)
    send_telegram(f"NodeSeek 签到报告\n\n{report}")

    log.info("\n" + "=" * 50)
    log.info("签到流程结束")
    log.info("=" * 50)


if __name__ == "__main__":
    main()
