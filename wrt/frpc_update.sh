#!/bin/sh
# update_frpc_openwrt.sh
#
# 在 OpenWRT 上手动把 frpc 升级到 laosan-xx/frp 指定/最新版本。
# 适用于老版本 frpc 没有内置 update_frpc 命令、无法自助更新的情况。
#
# 完全复刻 client/command_builtin.go 中 doUpdateFrpc() 的逻辑：
#   1. 解析目标版本（指定 或 取 GitHub 最新 release，带镜像与降级策略）
#   2. 下载 frp_<ver>_linux_<arch>.tar.gz
#   3. 解压，取出 frpc 二进制
#   4. ELF 头校验
#   5. 同目录暂存 .frpc_update_new -> 备份 frpc.bak -> 原子 rename 覆盖
#   6. 重启 frpc（/etc/init.d/frpc restart 等），并回滚保护
#
# 用法：
#   sh update_frpc_openwrt.sh                 # 升级到最新版
#   sh update_frpc_openwrt.sh --version 1.2.3 # 升级到指定版本
#   sh update_frpc_openwrt.sh --mirror https://gh.2026178.xyz
#   sh update_frpc_openwrt.sh --bin /usr/bin/frpc --no-restart
#   sh update_frpc_openwrt.sh --dry-run       # 只下载解压校验，不替换
#   sh update_frpc_openwrt.sh --no-follow     # 只转后台就返回，适合 cron
#   sh update_frpc_openwrt.sh --clean         # 只清理日志与状态文件后退出
#
# 说明：脚本会自动以脱离会话（setsid/nohup）的方式运行，SSH 断开也不会中断更新；
#       前台默认跟随日志直到结束并返回退出码。Ctrl+C 或断连只会退出“跟随”，
#       更新进程会继续跑完（含失败自动回滚）。输出写入 /tmp/frpc_update.log，
#       退出码写入 /tmp/frpc_update.done。
#
# 临时文件：日志超过 500 行自动裁剪到最近 200 行（可用 MAX_LOG_LINES /
#       KEEP_LOG_LINES 调整）；跟随模式下读到的 /tmp/frpc_update.done 会被删除，
#       --no-follow 模式保留供 cron 取结果。想彻底清理用 --clean。
#
# 依赖：curl 或 wget（busybox 均可）、tar、grep/sed/od。
set -u

REPO_OWNER="laosan-xx"
REPO_NAME="frp"

# ---- 可调参数（命令行可覆盖）---------------------------------------------
TARGET_VERSION=""          # 空 = 最新
FRPC_BIN=""                # 空 = 自动探测
MIRROR="https://gh.2026178.xyz"                  # 空 = 直连 github；或设置如 https://gh.2026178.xyz
NO_RESTART=0
DRY_RUN=0
TEST_ROLLBACK=0           # 1 = 替换+重启后强制模拟“版本不匹配”，用来演练回滚

LOG_FILE="${LOG_FILE:-/tmp/frpc_update.log}"
DONE_FILE="${DONE_FILE:-/tmp/frpc_update.done}"

# ---- 工具函数 ------------------------------------------------------------
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

cleanup() {
    rc=$?
    if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" 2>/dev/null
    fi
    if [ -n "${BIN_DIR:-}" ]; then
        rm -f "${BIN_DIR}/.frpc_update_new" 2>/dev/null
    fi
    if [ -n "${LOCK_DIR:-}" ] && [ -f "${LOCK_DIR}/pid" ] \
       && [ "$(cat "${LOCK_DIR}/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "${LOCK_DIR}" 2>/dev/null
    fi
    echo "$rc" > "${DONE_FILE}" 2>/dev/null
    return 0
}

# 仅在“二进制已替换但升级尚未确认成功”时生效，避免误回滚
rollback_now() {
    [ "${ROLLBACK_ARMED:-0}" = "1" ] || return 0
    ROLLBACK_ARMED=0
    log_warn "升级未确认成功，正在回滚 ${FRPC_PATH} ..."
    if [ -f "${BAK}" ] && mv "${BAK}" "${FRPC_PATH}" 2>/dev/null; then
        restart_frpc
        log_warn "已回滚到旧版本 ${CUR_VER:-未知}"
    else
        log_err "回滚失败！请手动执行: mv ${BAK} ${FRPC_PATH} && /etc/init.d/frpc start"
    fi
}

# SSH 断连会发 SIGHUP，之前未捕获，导致脚本在“替换后、回滚前”被杀死
on_signal() {
    log_warn "收到中断信号，正在安全收尾..."
    rollback_now
    exit 130
}

trap 'on_signal' INT TERM HUP
trap 'cleanup' EXIT

# 按 Go 的 arch 命名映射 uname -m
detect_arch() {
    m=$(uname -m 2>/dev/null)
    case "$m" in
        x86_64|amd64)        echo "amd64" ;;
        i386|i486|i586|i686) echo "386" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7*|armv6*|armv5*|arm) echo "arm" ;;
        mips64el|mips64le)   echo "mips64le" ;;
        mips64)              echo "mips64" ;;
        mipsel|mipsle)       echo "mipsle" ;;
        mips)                echo "mips" ;;
        riscv64)             echo "riscv64" ;;
        *) echo "" ;;
    esac
}

# 探测 frpc 可执行文件路径
detect_frpc() {
    # 1. 环境变量已指定
    if [ -n "$FRPC_BIN" ] && [ -x "$FRPC_BIN" ]; then
        echo "$FRPC_BIN"; return 0
    fi
    # 2. PATH 中查找
    p=$(command -v frpc 2>/dev/null)
    if [ -n "$p" ] && [ -x "$p" ]; then
        echo "$p"; return 0
    fi
    # 3. 常见路径
    for c in /usr/bin/frpc /usr/sbin/frpc /bin/frpc; do
        if [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    echo ""; return 1
}

# 取当前 frpc 版本：frpc --version 可能输出 "frpc version 0.80.2"、
# "frpc version v0.80.2"，也可能直接输出裸版本号 "0.80.2"。
# 用 grep -o 直接抓取 X.Y.Z 三段式，兼容上述各种格式；同时捕获
# stdout/stderr（部分构建把版本打到 stderr）。
current_version() {
    v=$("$1" --version 2>&1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n1)
    echo "$v"
}

# 把 github.com / api.github.com 按 MIRROR 重写
rewrite_url() {
    url="$1"
    if [ -z "$MIRROR" ]; then
        echo "$url"; return
    fi
    m=$(echo "$MIRROR" | sed 's:/*$::')
    echo "$url" | sed -e "s#https://api.github.com#${m}/api#g" -e "s#https://github.com#${m}#g"
}

# 下载 URL 到 OUTFILE；优先 curl，回退 wget
fetch() {
    url="$1"; out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$out"
    else
        log_err "缺少 curl 或 wget，无法下载"
        return 1
    fi
}

# 解析最新版本：GitHub API 优先，失败降级到 releases 页面爬取
resolve_latest() {
    api_url=$(rewrite_url "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")
    tmp=$(mktemp /tmp/frpapi.XXXXXX)
    if fetch "$api_url" "$tmp" && [ -s "$tmp" ]; then
        ver=$(sed -n 's/.*"tag_name"[ ]*:[ ]*"v\?\([0-9][0-9.]*\)".*/\1/p' "$tmp" | head -n1)
        rm -f "$tmp"
        if [ -n "$ver" ]; then echo "$ver"; return 0; fi
    fi
    rm -f "$tmp"

    log_warn "GitHub API 解析失败，尝试爬取 releases 页面..."
    page_url=$(rewrite_url "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases")
    tmp2=$(mktemp /tmp/frppage.XXXXXX)
    if fetch "$page_url" "$tmp2" && [ -s "$tmp2" ]; then
        ver=$(sed -n 's@.*releases/tag/v\([0-9][0-9.]*\).*@\1@p' "$tmp2" | head -n1)
        rm -f "$tmp2"
        if [ -n "$ver" ]; then echo "$ver"; return 0; fi
    fi
    rm -f "$tmp2"
    return 1
}

# 校验：直接尝试执行新二进制 --version。
# 这样既能验证它是本架构可用的可执行文件（错误架构会报 Exec format error），
# 又不依赖 od/hexdump 等 OpenWRT 上经常缺失的工具。
check_elf() {
    bin="$1"
    out=$("$bin" --version 2>&1)
    rc=$?
    if [ $rc -ne 0 ] || [ -z "$out" ]; then
        log_err "$bin 无法执行（可能不是本架构/有效的 frpc 二进制）: ${out}"
        return 1
    fi
    return 0
}

# 判断 frpc 进程是否真的在跑（只看版本不够：进程死了版本号照样能读到）
frpc_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof frpc >/dev/null 2>&1 && return 0
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep frpc >/dev/null 2>&1 && return 0
    fi
    # 最后的 ps 兜底要排除脚本自身（frpc_update.sh）和 init.d 脚本，避免误判
    ps 2>/dev/null | grep "[f]rpc" \
        | grep -vE "frpc_update|/etc/init\.d/frpc|grep" | grep -q . && return 0
    return 1
}

# 重启 frpc：尽量复用内置逻辑的顺序
restart_frpc() {
    if [ "$NO_RESTART" = "1" ]; then
        log_info "已跳过重启（--no-restart）"
        return 0
    fi
    if [ -x /etc/init.d/frpc ]; then
        log_info "执行 /etc/init.d/frpc restart"
        /etc/init.d/frpc restart
        rc=$?
        sleep 2
        # restart 是“先 stop 再 start”，中断或异常都可能停在已停止状态，这里补一次 start
        if ! frpc_running; then
            log_warn "restart 后未检测到 frpc 进程，补一次 start"
            /etc/init.d/frpc start
            rc=$?
            sleep 2
        fi
        return $rc
    fi
    if command -v service >/dev/null 2>&1 && service frpc restart 2>/dev/null; then
        log_info "执行 service frpc restart"
        sleep 2
        frpc_running && return 0
    fi
    # 兜底：只有在确认能重新拉起时才 kill，避免杀完起不来
    log_warn "未找到 frpc init 脚本，尝试 kill 后自行拉起"
    killall frpc 2>/dev/null
    sleep 1
    if [ -x "${FRPC_PATH:-}" ]; then
        nohup "$FRPC_PATH" -c /etc/frp/frpc.toml >/dev/null 2>&1 &
        sleep 2
    fi
    frpc_running
}

# ---- 自守护化：脱离 SSH 会话 ---------------------------------------------
# “替换二进制 → 重启 → 校验 → 回滚”是不可中断区，SSH 断连发来的 SIGHUP 会把
# 脚本连同 /etc/init.d/frpc 一起杀掉，导致 frpc 停在已停止状态且无人回滚。
# 这里把自己 re-exec 成脱离会话的后台进程，输出全部写入日志文件。
HELP_ONLY=0
FOLLOW=1
CLEAN_ONLY=0
for _a in "$@"; do
    case "$_a" in
        -h|--help) HELP_ONLY=1 ;;
        --no-follow) FOLLOW=0 ;;   # 只转后台就返回，适合 cron / 无人值守
        --clean) CLEAN_ONLY=1 ;;   # 只清理日志/状态文件后退出
    esac
done

# 手动清理：日志、结束标记、残留锁
if [ "$CLEAN_ONLY" = "1" ]; then
    rm -f "$LOG_FILE" "$DONE_FILE"
    rm -rf "${LOCK_DIR:-/tmp/frpc_update.lock}"
    echo "[INFO] 已清理: $LOG_FILE $DONE_FILE ${LOCK_DIR:-/tmp/frpc_update.lock}"
    exit 0
fi

if [ "${FRPC_UPDATER_DAEMON:-}" != "1" ] && [ "$HELP_ONLY" = "0" ]; then
    # 父进程不需要守护进程的 trap（它的 EXIT trap 会抢先写 DONE_FILE）
    trap - EXIT INT TERM HUP

    rm -f "$DONE_FILE"
    # 先确保日志文件存在（/tmp 重启后常被清空），再记下当前行数；
    # 稍后 tail 只跟随本次追加的内容，不回放历史。
    # 注意：不能靠 wc 的 2>/dev/null 兜底——输入重定向失败是 shell 报的，压不住。
    : >> "$LOG_FILE" || { log_err "无法写入日志文件 $LOG_FILE"; exit 1; }

    # 日志轮转：/tmp 在路由器上多是 tmpfs，长期累积会占内存。
    # 不直接删日志——它是排障依据，超限只保留尾部。
    MAX_LOG_LINES="${MAX_LOG_LINES:-500}"
    KEEP_LOG_LINES="${KEEP_LOG_LINES:-200}"
    _lines=$(wc -l < "$LOG_FILE")
    if [ "${_lines:-0}" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$KEEP_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
            && mv "${LOG_FILE}.tmp" "$LOG_FILE" \
            && echo "[INFO] 日志超过 ${MAX_LOG_LINES} 行，已裁剪为最近 ${KEEP_LOG_LINES} 行"
        rm -f "${LOG_FILE}.tmp"
    fi

    _start=$(wc -l < "$LOG_FILE")
    _dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    _self="${_dir:-.}/$(basename "$0")"
    if command -v setsid >/dev/null 2>&1; then
        setsid env FRPC_UPDATER_DAEMON=1 LOG_FILE="$LOG_FILE" DONE_FILE="$DONE_FILE" \
            LOCK_DIR="${LOCK_DIR:-/tmp/frpc_update.lock}" \
            sh "$_self" "$@" </dev/null >>"$LOG_FILE" 2>&1 &
    else
        nohup env FRPC_UPDATER_DAEMON=1 LOG_FILE="$LOG_FILE" DONE_FILE="$DONE_FILE" \
            LOCK_DIR="${LOCK_DIR:-/tmp/frpc_update.lock}" \
            sh "$_self" "$@" </dev/null >>"$LOG_FILE" 2>&1 &
    fi
    echo "[INFO] 更新任务已脱离当前会话，SSH 断开也不会中断。"
    echo "[INFO] 日志文件（追加模式，每次运行有分隔行）: $LOG_FILE"

    if [ "$FOLLOW" = "0" ]; then
        echo "[INFO] 已后台运行，未跟随日志。查看进度: tail -f $LOG_FILE"
        exit 0
    fi

    # 跟随日志直到后台任务结束：既保留原来的实时输出体验，
    # 又保证 Ctrl+C / 断连只退出“跟随”，更新进程继续跑完。
    _pidfile="${LOCK_DIR:-/tmp/frpc_update.lock}/pid"
    _i=0
    while [ ! -s "$_pidfile" ] && [ "$_i" -lt 10 ]; do sleep 1; _i=$((_i + 1)); done
    _dpid=$(cat "$_pidfile" 2>/dev/null)

    # Ctrl+C / SSH 断开只退出“跟随”，守护进程继续跑完（含失败自动回滚）
    stop_follow() {
        kill "$_tailpid" 2>/dev/null
        echo
        echo "[INFO] 已退出跟随，更新任务仍在后台继续（日志: $LOG_FILE）"
        exit 0
    }
    trap 'stop_follow' INT TERM HUP

    # 只跟随本次追加的内容
    tail -n +$((_start + 1)) -f "$LOG_FILE" 2>/dev/null &
    _tailpid=$!
    sleep 1
    if ! kill -0 "$_tailpid" 2>/dev/null; then
        # 个别 busybox 不支持 -n +N 与 -f 连用，退回普通跟随
        tail -f "$LOG_FILE" 2>/dev/null &
        _tailpid=$!
    fi

    _i=0
    while [ ! -s "$DONE_FILE" ] && [ "$_i" -lt 600 ]; do
        [ -n "$_dpid" ] && kill -0 "$_dpid" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
    done
    sleep 1
    kill "$_tailpid" 2>/dev/null
    wait "$_tailpid" 2>/dev/null

    _rc=$(cat "$DONE_FILE" 2>/dev/null)
    # 结果已由前台显示，删除标记文件，避免留下过期的 done 误导后续判断
    # （--no-follow 模式保留，cron 要靠它取结果）
    rm -f "$DONE_FILE"
    echo
    echo "[INFO] 更新结束，退出码: ${_rc:-未知}"
    exit "${_rc:-1}"
fi

# ---- 互斥锁：防止重复启动导致两个进程并发替换同一个二进制 -----------------
LOCK_DIR="${LOCK_DIR:-/tmp/frpc_update.lock}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "${_old:-}" ] && kill -0 "$_old" 2>/dev/null; then
        log_err "已有更新任务在运行（PID $_old），本次退出。进度: tail -f $LOG_FILE"
        exit 1
    fi
    log_warn "清理上次残留的锁（PID ${_old:-未知} 已不存在）"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || { log_err "无法创建锁目录 $LOCK_DIR"; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"

# 日志是追加写入的，多次运行会混在一起，打一行分隔便于区分
echo "===== $(date '+%F %T') frpc_update 开始 (PID $$) 参数: $* ====="

# ---- 解析命令行 ----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --version) TARGET_VERSION="$2"; shift 2 ;;
        --bin)     FRPC_BIN="$2"; shift 2 ;;
        --mirror)  MIRROR="$2"; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        --no-follow) shift ;;              # 仅父进程使用，此处忽略
        --dry-run) DRY_RUN=1; shift ;;
        --test-rollback) TEST_ROLLBACK=1; shift ;;
        -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
        *) log_err "未知参数: $1"; exit 1 ;;
    esac
done

# ---- 主流程 --------------------------------------------------------------
ARCH=$(detect_arch)
if [ -z "$ARCH" ]; then
    log_err "无法识别当前架构 ($(uname -m))，请手动指定或反馈"
    exit 1
fi
log_info "检测到架构: linux/${ARCH}"

FRPC_PATH=$(detect_frpc)
if [ -z "$FRPC_PATH" ]; then
    log_err "未找到 frpc 可执行文件，请用 --bin 指定路径"
    exit 1
fi
log_info "当前 frpc 路径: ${FRPC_PATH}"

CUR_VER=$(current_version "$FRPC_PATH")
log_info "当前版本: ${CUR_VER:-未知}"

if [ -z "$TARGET_VERSION" ]; then
    log_info "解析最新版本..."
    TARGET_VERSION=$(resolve_latest) || { log_err "无法解析最新版本"; exit 1; }
fi
log_info "目标版本: ${TARGET_VERSION}"

# 已是目标版本则跳过
norm() { echo "$1" | sed 's/^v//'; }
if [ -n "$CUR_VER" ] && [ "$(norm "$CUR_VER")" = "$(norm "$TARGET_VERSION")" ]; then
    log_info "已经是最新版本 ${TARGET_VERSION}，无需更新"
    exit 0
fi

ASSET="frp_${TARGET_VERSION}_linux_${ARCH}.tar.gz"
DL_URL=$(rewrite_url "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${TARGET_VERSION}/${ASSET}")
log_info "下载地址: ${DL_URL}"

WORK_DIR=$(mktemp -d /tmp/frp_update.XXXXXX)
ARCHIVE="${WORK_DIR}/${ASSET}"
EXTRACT="${WORK_DIR}/extracted"

log_info "下载中..."
if ! fetch "$DL_URL" "$ARCHIVE"; then
    log_err "下载失败: ${DL_URL}"
    exit 1
fi
if [ ! -s "$ARCHIVE" ]; then
    log_err "下载文件为空"
    exit 1
fi

log_info "解压中..."
mkdir -p "$EXTRACT"
if ! tar -xzf "$ARCHIVE" -C "$EXTRACT" 2>/dev/null; then
    log_err "解压失败"
    exit 1
fi

NEW_BIN="${EXTRACT}/frp_${TARGET_VERSION}_linux_${ARCH}/frpc"
if [ ! -f "$NEW_BIN" ]; then
    log_err "压缩包中未找到 frpc 可执行文件 (期望: ${NEW_BIN})"
    exit 1
fi
chmod 755 "$NEW_BIN"

if ! check_elf "$NEW_BIN"; then
    exit 1
fi
log_info "新 frpc 校验通过: $(${NEW_BIN} --version 2>&1 | head -n1 || echo unknown)"

if [ "$DRY_RUN" = "1" ]; then
    log_info "[dry-run] 校验完成，未替换二进制。新文件位于: ${NEW_BIN}"
    exit 0
fi

# ---- 原子替换（复刻 doUpdateFrpc）---------------------------------------
BIN_DIR=$(dirname "$FRPC_PATH")
STAGE="${BIN_DIR}/.frpc_update_new"
BAK="${FRPC_PATH}.bak"

log_info "暂存新二进制..."
cp "$NEW_BIN" "$STAGE" || { log_err "暂存失败"; exit 1; }
chmod 755 "$STAGE" || { log_err "设置权限失败"; rm -f "$STAGE"; exit 1; }

# 旧备份若与当前版本不同，保留为 frpc.bak.<版本>。
# 否则重复运行时会把 .bak 覆盖成刚装上的新版，导致彻底失去回退能力。
if [ -f "$BAK" ]; then
    bak_ver=$(current_version "$BAK")
    if [ -n "$bak_ver" ] && [ "$(norm "$bak_ver")" != "$(norm "$CUR_VER")" ]; then
        mv "$BAK" "${BAK}.${bak_ver}" 2>/dev/null \
            && log_warn "旧备份保留为 ${BAK}.${bak_ver}"
    else
        rm -f "$BAK"
    fi
fi
if ! cp "$FRPC_PATH" "$BAK"; then
    log_err "备份当前 frpc 失败"
    rm -f "$STAGE"; exit 1
fi

log_info "原子替换 ${FRPC_PATH} ..."
if ! mv "$STAGE" "$FRPC_PATH"; then
    log_err "替换失败，尝试回滚"
    mv "$BAK" "$FRPC_PATH" 2>/dev/null
    rm -f "$STAGE"
    exit 1
fi
log_info "替换完成，已备份旧版本到 ${BAK}"
# 从此刻起进入“未确认”状态：任何中断/失败都会触发回滚
ROLLBACK_ARMED=1

# 延迟后重启（与内置逻辑一致，给文件句柄一点释放时间）
log_info "300ms 后重启 frpc..."
sleep 0.3 2>/dev/null || sleep 1
restart_frpc

# 进程本身没起来比版本不匹配更严重，优先处理
if [ "$NO_RESTART" != "1" ] && ! frpc_running; then
    log_err "重启后 frpc 进程未运行，尝试回滚"
    rollback_now
    exit 1
fi

# 校验新版本
sleep 2
if [ "$TEST_ROLLBACK" = "1" ]; then
    log_warn "[test-rollback] 强制模拟：重启后版本校验不匹配，进入回滚分支"
    NEW_VER="9.9.9"
else
    NEW_VER=$(current_version "$FRPC_PATH")
fi
if [ -n "$NEW_VER" ] && [ "$(norm "$NEW_VER")" = "$(norm "$TARGET_VERSION")" ]; then
    ROLLBACK_ARMED=0
    log_info "升级成功：frpc 现在为 v${NEW_VER}"

    # 新版本已确认在跑，备份不再需要；进程没起来则保留，留手动回退的余地
    if [ "$NO_RESTART" = "1" ]; then
        log_warn "本次未重启（--no-restart），保留备份 ${BAK}"
    elif frpc_running; then
        rm -f "$BAK" && log_info "新版本已正常运行，已删除备份 ${BAK}"
    else
        log_warn "frpc 进程未运行，保留备份 ${BAK} 以便手动回退"
    fi
    exit 0
elif [ -z "$NEW_VER" ]; then
    # 解析不到版本：无法确认成功与否，但新二进制已通过可执行性校验，
    # 不盲目回滚（回滚反而可能把刚换上的新版换掉）。提示用户手动确认。
    ROLLBACK_ARMED=0
    log_warn "重启后未能解析到 frpc 版本（${FRPC_PATH} --version 输出异常），未做回滚。"
    log_warn "请手动执行: ${FRPC_PATH} --version  确认实际版本；若确为 ${TARGET_VERSION} 则升级已成功。"
    log_warn "原始 --version 输出: $("$FRPC_PATH" --version 2>&1 | head -n3)"
    exit 0
else
    log_warn "重启后版本为 ${NEW_VER}（期望 ${TARGET_VERSION}），尝试回滚"
    rollback_now
    exit 1
fi
