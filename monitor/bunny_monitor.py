# BunnyVPS US_基础版 库存监控脚本
# 检测 https://bunnyvps.io/index.php?rp=/store/us-vps 中 US_基础版 是否有货
# 有货时通过 Telegram Bot 发送通知

# sudo python3 bunny_monitor.py --install      # 直接安装并启用开机自启
# sudo python3 bunny_monitor.py --uninstall    # 停止并移除开机自启
# python3 bunny_monitor.py                     # 仅运行监控（无参数）
# sudo python3 bunny_monitor.py --service-menu # 显示服务菜单

import requests
import re
import time
import logging
import os
import sys
import subprocess
from datetime import datetime

# ============ 配置区域 ============
# 监控页面 URL
MONITOR_URL = "https://bunnyvps.io/index.php?rp=/store/us-vps"

# 监控的产品名称关键词
PRODUCT_KEYWORD = "US_基础版"

# 检查间隔（秒）
CHECK_INTERVAL = 60

# Telegram 通知配置
TG_BOT_TOKEN = "7622740934:AAETTKoZ_E0EYxUbINpEdzMi__i09uqyqsA"  # 填入你的 Bot Token，例如：123456:ABC-DEF
TG_CHAT_ID = "812793390"    # 填入你的 Chat ID，例如：123456789

# 请求超时（秒）
REQUEST_TIMEOUT = 30

# ============ 日志配置 ============
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("bunny_monitor")


def send_telegram(message: str) -> bool:
    """发送 Telegram 通知"""
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        log.warning("Telegram Bot Token 或 Chat ID 未配置，跳过通知")
        return False
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TG_CHAT_ID,
        "text": message,
        "parse_mode": "HTML",
    }
    try:
        resp = requests.post(url, json=payload, timeout=REQUEST_TIMEOUT)
        if resp.status_code == 200:
            log.info("Telegram 通知发送成功")
            return True
        else:
            log.error(f"Telegram 通知发送失败: {resp.status_code} {resp.text}")
            return False
    except Exception as e:
        log.error(f"Telegram 通知发送异常: {e}")
        return False


def check_stock() -> dict | None:
    """
    检查 US_基础版 库存状态。
    返回 {"product": "US_基础版", "in_stock": bool} 或 None（请求失败时）。
    """
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    }
    try:
        resp = requests.get(MONITOR_URL, headers=headers, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
    except Exception as e:
        log.error(f"请求页面失败: {e}")
        return None

    html = resp.text

    # 策略：在页面中定位 US_基础版 产品区块，然后检查该区块内是否包含 "0 Available"
    # 无货时产品区块内会有 "0 Available" 字样，有货时没有此字样

    # 用正则截取 US_基础版 附近的内容块（从标题到下一个产品标题之间）
    # 页面结构中每个产品以 ### 分隔，我们查找包含 US_基础版 的部分
    pattern = rf"(US_基础版.*?)(?:(?=US\s+进阶版)|(?:=Customization)|$)"
    match = re.search(pattern, html, re.DOTALL | re.IGNORECASE)

    if not match:
        log.warning(f"未在页面中找到产品 '{PRODUCT_KEYWORD}'，尝试全页面检测")
        # 备选：直接在整个页面中查找关键词附近是否有 0 Available
        # 这种情况可能是页面结构变了
        if PRODUCT_KEYWORD in html:
            # 查找关键词附近 500 字符内是否有 0 Available
            idx = html.index(PRODUCT_KEYWORD)
            nearby = html[idx : idx + 500]
            in_stock = "0 Available" not in nearby
            return {"product": PRODUCT_KEYWORD, "in_stock": in_stock}
        return None

    block = match.group(1)
    in_stock = "0 Available" not in block

    return {"product": PRODUCT_KEYWORD, "in_stock": in_stock}


# ============ systemd 配置 ============
SERVICE_NAME = "bunny-monitor"
SERVICE_FILE = f"/etc/systemd/system/{SERVICE_NAME}.service"


def get_script_path():
    """获取当前脚本的绝对路径"""
    return os.path.abspath(sys.argv[0])


def is_service_installed():
    """检查 systemd 服务是否已安装"""
    return os.path.exists(SERVICE_FILE)


def is_service_enabled():
    """检查 systemd 服务是否已启用开机自启"""
    try:
        result = subprocess.run(
            ["systemctl", "is-enabled", SERVICE_NAME],
            capture_output=True, text=True
        )
        return result.stdout.strip() == "enabled"
    except Exception:
        return False


def get_service_status():
    """获取服务当前运行状态"""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SERVICE_NAME],
            capture_output=True, text=True
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


def install_service():
    """安装并启用 systemd 开机自启服务"""
    if os.name != "posix":
        print("开机自启功能仅支持 Linux 系统")
        return

    script_path = get_script_path()
    python_path = sys.executable

    service_content = f"""[Unit]
Description=BunnyVPS Stock Monitor
After=network.target

[Service]
Type=simple
ExecStart={python_path} {script_path}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
"""
    try:
        with open(SERVICE_FILE, "w") as f:
            f.write(service_content)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", SERVICE_NAME], check=True)
        subprocess.run(["systemctl", "start", SERVICE_NAME], check=True)
        print(f"开机自启已配置完成，服务已启动")
        print(f"  服务文件: {SERVICE_FILE}")
        print(f"  脚本路径: {script_path}")
        print(f"  Python:   {python_path}")
    except PermissionError:
        print("权限不足，请使用 sudo 运行此脚本")
    except subprocess.CalledProcessError as e:
        print(f"配置失败: {e}")
    except FileNotFoundError:
        print("systemctl 未找到，当前系统可能不支持 systemd")


def uninstall_service():
    """停止并卸载 systemd 开机自启服务"""
    try:
        subprocess.run(["systemctl", "stop", SERVICE_NAME], capture_output=True)
        subprocess.run(["systemctl", "disable", SERVICE_NAME], capture_output=True)
        if os.path.exists(SERVICE_FILE):
            os.remove(SERVICE_FILE)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        print("开机自启已移除，服务已停止")
    except PermissionError:
        print("权限不足，请使用 sudo 运行此脚本")
    except Exception as e:
        print(f"卸载失败: {e}")


def service_menu():
    """开机自启配置菜单"""
    if os.name != "posix":
        print("开机自启功能仅支持 Linux 系统")
        return

    print("\n" + "=" * 50)
    print("  BunnyVPS 监控 - 开机自启配置")
    print("=" * 50)

    # 显示当前状态
    installed = is_service_installed()
    enabled = is_service_enabled()
    active = get_service_status()
    print(f"\n当前状态:")
    print(f"  服务文件: {'已安装' if installed else '未安装'}")
    print(f"  开机自启: {'已启用' if enabled else '未启用'}")
    print(f"  运行状态: {active}")
    print()

    print("1. 安装并启用开机自启")
    print("2. 停止并移除开机自启")
    print("3. 查看服务日志")
    print("0. 返回监控")
    print()

    choice = input("请选择 [0-3]: ").strip()

    if choice == "1":
        install_service()
    elif choice == "2":
        uninstall_service()
    elif choice == "3":
        try:
            subprocess.run(["journalctl", "-u", SERVICE_NAME, "-f", "--no-pager", "-n", "50"])
        except Exception as e:
            print(f"查看日志失败: {e}")
    elif choice == "0":
        return
    else:
        print("无效选择")


def main():
    # 如果传入 --install 参数，直接安装服务
    if len(sys.argv) > 1:
        if sys.argv[1] == "--install":
            install_service()
            return
        elif sys.argv[1] == "--uninstall":
            uninstall_service()
            return
        elif sys.argv[1] == "--service-menu":
            service_menu()
            return

    log.info("=" * 50)
    log.info("BunnyVPS 库存监控启动")
    log.info(f"监控页面: {MONITOR_URL}")
    log.info(f"监控产品: {PRODUCT_KEYWORD}")
    log.info(f"检查间隔: {CHECK_INTERVAL} 秒")
    log.info(f"Telegram 通知: {'已配置' if TG_BOT_TOKEN and TG_CHAT_ID else '未配置'}")
    log.info("=" * 50)

    last_in_stock = False  # 避免重复通知

    while True:
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        result = check_stock()

        if result is None:
            log.warning(f"[{now}] 检查失败，等待下次重试")
        else:
            status = "有货！" if result["in_stock"] else "无货"
            log.info(f"[{now}] {result['product']} 状态: {status}")

            if result["in_stock"] and not last_in_stock:
                msg = (
                    f"🚀 <b>BunnyVPS 库存提醒</b>\n\n"
                    f"<b>{PRODUCT_KEYWORD}</b> 现在有货了！\n\n"
                    f"🔗 <a href=\"{MONITOR_URL}\">立即抢购</a>\n\n"
                    f"时间: {now}"
                )
                send_telegram(msg)
                last_in_stock = True
            elif not result["in_stock"]:
                last_in_stock = False

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
