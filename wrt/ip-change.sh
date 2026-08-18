#!/bin/sh

# 配置信息
TOKEN="7622740934:AAETTKoZ_E0EYxUbINpEdzMi__i09uqyqsA"
CHAT_ID="812793390"
LOG_FILE="/root/ip.log"

# 获取 IP (使用更健壮的 sed 过滤)
CURRENT_IP=$(curl -s --connect-timeout 10 cip.cc | grep "^IP" | sed 's/.*: //' | xargs)

# 检查是否成功获取 IP
if [ -z "$CURRENT_IP" ]; then
    echo "$(date) - 错误: 无法连接到 cip.cc 或解析失败" >> /root/ip_error.log
    exit 1
fi

# 读取上次保存的 IP
if [ -f "$LOG_FILE" ]; then
    LAST_IP=$(cat $LOG_FILE)
else
    LAST_IP="First_Run"
fi

# 对比并通知
if [ "$CURRENT_IP" != "$LAST_IP" ]; then
    # 发送 Telegram 通知
    MESSAGE="🌐 OpenWrt IP 变动通知%0A----------------------%0A旧 IP: $LAST_IP%0A新 IP: $CURRENT_IP%0A时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    RES=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$MESSAGE")
    
    # 检查 Telegram 发送状态
    if echo "$RES" | grep -q '"ok":true'; then
        echo "$CURRENT_IP" > $LOG_FILE
        echo "$(date) - IP 已更新并通知成功"
    else
        echo "$(date) - 通知发送失败: $RES" >> /root/ip_error.log
    fi
else
    # IP 没变，静默退出（或取消下面行的注释用于调试）
    # echo "$(date) - IP 未变: $CURRENT_IP"
    :
fi