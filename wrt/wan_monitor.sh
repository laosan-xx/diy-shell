#!/bin/sh

# ================= 配置项 =================
TARGET="auto"                  # auto=自动跟随WAN默认网关；也可填固定IP（光猫IP或外网IP如 223.5.5.5）
FALLBACK="223.5.5.5"           # auto 模式拿不到默认网关时的兜底目标
LOG_FILE="/root/wan_ping.log"  # 日志保存路径
PID_FILE="/root/wan_ping.pid"  # 进程号保存路径
INTERVAL=1                     # 每次 ping 的间隔秒数
LOG_MAX=5000                   # 日志最多保留行数（约 600KB）
ROTATE_EVERY=60                # 每 ping 多少次检查一次日志行数
# ==========================================

SCRIPT=$(readlink -f "$0" 2>/dev/null || echo "$0")

# 解析监测目标：auto 时取 WAN 默认网关
resolve_target() {
    if [ "$TARGET" != "auto" ]; then
        echo "$TARGET"
        return
    fi
    GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
    [ -z "$GW" ] && GW=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $2; exit}')
    [ -z "$GW" ] && GW="$FALLBACK"
    echo "$GW"
}

# 取 WAN 口当前 IP（默认路由所在接口）
wan_ip() {
    IF=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
    [ -z "$IF" ] && IF=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $8; exit}')
    [ -z "$IF" ] && { echo "-"; return; }
    IP=$(ip -4 addr show dev "$IF" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    [ -z "$IP" ] && IP="-"
    echo "$IP"
}

# 超过上限只保留最近 LOG_MAX 行（先写临时文件再 mv，避免与写入进程抢文件句柄）
rotate_log() {
    [ -f "$LOG_FILE" ] || return
    N=$(wc -l < "$LOG_FILE" 2>/dev/null)
    [ -z "$N" ] && return
    if [ "$N" -gt "$LOG_MAX" ]; then
        tail -n "$LOG_MAX" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

run_loop() {
    : > "$LOG_FILE"
    i=0
    while true; do
        T=$(resolve_target)
        W=$(wan_ip)
        R=$(ping -c 1 -W 1 "$T" 2>/dev/null | grep -o "bytes from.*")
        [ -z "$R" ] && R="PING FAILED"
        printf '%s - [%s|%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$T" "$W" "$R" >> "$LOG_FILE"
        i=$((i + 1))
        if [ "$i" -ge "$ROTATE_EVERY" ]; then
            i=0
            rotate_log
        fi
        sleep "$INTERVAL"
    done
}

start_monitor() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "❌ 监测已经在运行中 (PID: $(cat "$PID_FILE"))"
        return
    fi

    echo "🚀 正在启动 WAN/光猫 连续监测..."
    echo "   目标: $(resolve_target)  WAN IP: $(wan_ip)  间隔: ${INTERVAL}s  日志上限: ${LOG_MAX} 行"
    nohup sh "$SCRIPT" __run >/dev/null 2>&1 &

    echo $! > "$PID_FILE"
    echo "✅ 启动成功！PID: $(cat "$PID_FILE")"
    echo "📄 日志文件: $LOG_FILE"
}

stop_monitor() {
    if [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "⚠️ 监测未在运行或 PID 文件不存在。"
        rm -f "$PID_FILE"
        return
    fi

    PID=$(cat "$PID_FILE")
    echo "🛑 正在停止监测 (PID: $PID)..."
    kill "$PID" 2>/dev/null
    rm -f "$PID_FILE"
    echo "✅ 已停止。"
}

status_monitor() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "👉 监测正在运行中 (PID: $(cat "$PID_FILE"))"
        echo "   目标: $(resolve_target)  WAN IP: $(wan_ip)  日志行数: $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)/${LOG_MAX}"
        echo "--- 最近 60 条日志 ---"
        tail -n 60 "$LOG_FILE" 2>/dev/null
        echo "---------------------"
    else
        echo "❌ 监测当前未运行"
    fi
}

log_monitor() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "⚠️ 日志文件不存在，请先启动监测。"
        return
    fi
    echo "📄 正在实时查看日志 (按 Ctrl+C 退出)..."
    tail -f "$LOG_FILE"
}

case "$1" in
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    status)
        status_monitor
        ;;
    log)
        log_monitor
        ;;
    __run)
        run_loop
        ;;
    *)
        echo "📌 用法: $0 {start | stop | status | log}"
        exit 1
        ;;
esac
