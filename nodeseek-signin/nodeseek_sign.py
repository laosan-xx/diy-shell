#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NodeSeek 论坛自动签到工具
- 支持 Cookie 或 账号密码登录
- 账号密码登录通过 patchright 浏览器自动求解 Cloudflare Turnstile 验证码（免费，无需打码平台）
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


# ==================== 账号密码登录（patchright 浏览器求解 Turnstile）====================
def login_with_credentials(username, password):
    """
    使用账号密码登录 NodeSeek，返回 Cookie 字符串
    通过 patchright 启动无头浏览器，加载登录页让 Cloudflare Turnstile 自动求解，
    在浏览器内调用登录 API 确保 token 与会话一致，最后提取浏览器 Cookie。
    无需任何第三方打码平台，完全免费。
    """
    try:
        from patchright.sync_api import sync_playwright
    except ImportError:
        log.error("patchright 未安装，无法使用账号密码登录")
        log.error("请执行: pip install patchright && python -m patchright install chromium")
        return None

    # headless 模式：默认 True，Cloudflare 检测严格时可设为 False（GitHub Actions 需配合 xvfb）
    headless = get_env("NS_HEADLESS", "true") != "false"

    log.info(f"正在使用浏览器登录: {username}（headless={headless}）")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        context = browser.new_context(user_agent=DEFAULT_UA)
        page = context.new_page()

        try:
            # 1. 访问登录页
            log.info("访问登录页...")
            page.goto(LOGIN_PAGE, timeout=30000)
            try:
                page.wait_for_load_state("networkidle", timeout=15000)
            except Exception:
                pass

            # 2. 等待 Cloudflare Turnstile 自动求解
            log.info("等待 Turnstile 验证码自动求解...")
            token = None
            try:
                page.wait_for_function(
                    """() => {
                        // 检查 cf-turnstile-response 隐藏输入框
                        const el = document.querySelector('[name="cf-turnstile-response"]');
                        if (el && el.value && el.value.length > 10) return true;
                        // 检查 Turnstile 组件的 data-response 属性
                        const widget = document.querySelector('.cf-turnstile');
                        if (widget) {
                            const r = widget.getAttribute('data-response');
                            if (r && r.length > 10) return true;
                        }
                        return false;
                    }""",
                    timeout=30000,
                )
                token = page.evaluate(
                    """() => {
                        const el = document.querySelector('[name="cf-turnstile-response"]');
                        if (el && el.value && el.value.length > 10) return el.value;
                        const widget = document.querySelector('.cf-turnstile');
                        if (widget) {
                            const r = widget.getAttribute('data-response');
                            if (r) return r;
                        }
                        return null;
                    }"""
                )
            except Exception:
                pass

            if not token:
                log.error("Turnstile 验证码求解超时，登录失败")
                browser.close()
                return None

            log.info("Turnstile 验证码求解成功")

            # 3. 在浏览器内调用登录 API（确保 token 与会话一致）
            log.info("调用登录接口...")
            result = page.evaluate(
                """async (args) => {
                    try {
                        const resp = await fetch(args.loginApi, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({
                                username: args.username,
                                password: args.password,
                                token: args.token,
                                source: 'turnstile'
                            })
                        });
                        return await resp.json();
                    } catch(e) {
                        return { success: false, message: e.toString() };
                    }
                }""",
                {
                    "loginApi": LOGIN_API,
                    "username": username,
                    "password": password,
                    "token": token,
                },
            )

            if result and result.get("success"):
                # 4. 提取浏览器 Cookie
                cookies = context.cookies()
                cookie_str = "; ".join(f"{c['name']}={c['value']}" for c in cookies)
                browser.close()
                log.info("账号密码登录成功")
                return cookie_str
            else:
                msg = result.get("message", "未知错误") if result else "无响应"
                log.error(f"登录失败: {msg}")
                browser.close()
                return None

        except Exception as e:
            log.error(f"浏览器登录异常: {e}")
            browser.close()
            return None


# ==================== 签到 ====================
def sign_in(cookie, random_mode="true"):
    """
    执行签到操作
    :param cookie: NodeSeek Cookie 字符串
    :param random_mode: "true"=随机签到(1~N鸡腿), "false"=固定签到(鸡腿x5)
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
        resp = requests.post(url, headers=headers, impersonate="chrome110", timeout=30)
        data = resp.json()
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


# ==================== GitHub 变量更新 ====================
def save_cookie_to_github(cookie_str):
    """
    将 Cookie 保存到 GitHub Actions 仓库变量
    需要 GH_PAT (有 repo / Actions 变量写权限) 和 GITHUB_REPOSITORY 环境变量
    """
    token = get_env("GH_PAT")
    repo = os.environ.get("GITHUB_REPOSITORY", "")

    if not token or not repo:
        log.warning("GH_PAT 或 GITHUB_REPOSITORY 未设置，跳过 GitHub 变量更新")
        return False

    var_name = "NS_COOKIE"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }

    # 尝试更新已有变量
    url = f"https://api.github.com/repos/{repo}/actions/variables/{var_name}"
    try:
        resp = requests.patch(
            url,
            headers=headers,
            json={"name": var_name, "value": cookie_str},
            timeout=30,
        )
        if resp.status_code == 204:
            log.info(f"GitHub 变量 {var_name} 更新成功")
            return True
        elif resp.status_code == 404:
            # 变量不存在，创建
            create_url = f"https://api.github.com/repos/{repo}/actions/variables"
            resp = requests.post(
                create_url,
                headers=headers,
                json={"name": var_name, "value": cookie_str},
                timeout=30,
            )
            if resp.status_code == 201:
                log.info(f"GitHub 变量 {var_name} 创建成功")
                return True
            log.error(f"GitHub 变量创建失败: {resp.status_code} {resp.text}")
            return False
        else:
            log.error(f"GitHub 变量更新失败: {resp.status_code} {resp.text}")
            return False
    except Exception as e:
        log.error(f"GitHub 变量更新异常: {e}")
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

    for idx, acc in enumerate(accounts):
        log.info(f"\n--- 账号 {idx + 1}/{len(accounts)} ---")

        # 账号间随机延迟
        if idx > 0:
            gap = random.randint(10, 60)
            log.info(f"等待 {gap} 秒...")
            time.sleep(gap)

        cookie = acc["cookie"]

        # 如果没有 Cookie 但有账号密码，尝试登录
        if not cookie and acc["username"] and acc["password"]:
            log.info("无 Cookie，使用账号密码登录...")
            cookie = login_with_credentials(acc["username"], acc["password"])
            if not cookie:
                results.append(f"账号{idx + 1}: 登录失败")
                continue
            updated_cookies.append(cookie)
            cookie_changed = True
        elif not cookie:
            results.append(f"账号{idx + 1}: 无 Cookie 且无账号密码配置")
            continue
        else:
            updated_cookies.append(cookie)

        # 执行签到
        status, message = sign_in(cookie, ns_random)

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
                new_cookie = login_with_credentials(acc["username"], acc["password"])
                if new_cookie:
                    updated_cookies[-1] = new_cookie
                    cookie_changed = True
                    status, message = sign_in(new_cookie, ns_random)
                    if status == "success":
                        results.append(f"账号{idx + 1}: 重新登录后签到成功 - {message}")
                    elif status == "already":
                        results.append(f"账号{idx + 1}: 重新登录后今日已签到 - {message}")
                    else:
                        results.append(f"账号{idx + 1}: 重新登录后签到失败 - {message}")
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
