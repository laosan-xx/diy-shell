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

# ---- 工具函数 ------------------------------------------------------------
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

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

# 重启 frpc：尽量复用内置逻辑的顺序
restart_frpc() {
    if [ "$NO_RESTART" = "1" ]; then
        log_info "已跳过重启（--no-restart）"
        return 0
    fi
    if [ -x /etc/init.d/frpc ]; then
        log_info "执行 /etc/init.d/frpc restart"
        /etc/init.d/frpc restart
        return $?
    fi
    if command -v service >/dev/null 2>&1 && service frpc restart 2>/dev/null; then
        log_info "执行 service frpc restart"
        return 0
    fi
    log_warn "未找到 frpc init 脚本，尝试 kill 后由 procd 拉起"
    killall frpc 2>/dev/null
    sleep 1
    return 0
}

# ---- 解析命令行 ----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --version) TARGET_VERSION="$2"; shift 2 ;;
        --bin)     FRPC_BIN="$2"; shift 2 ;;
        --mirror)  MIRROR="$2"; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --test-rollback) TEST_ROLLBACK=1; shift ;;
        -h|--help) sed -n '3,40p' "$0"; exit 0 ;;
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

if [ -f "$BAK" ]; then rm -f "$BAK"; fi
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

# 延迟后重启（与内置逻辑一致，给文件句柄一点释放时间）
log_info "300ms 后重启 frpc..."
sleep 0.3 2>/dev/null || sleep 1
restart_frpc

# 校验新版本
sleep 2
if [ "$TEST_ROLLBACK" = "1" ]; then
    log_warn "[test-rollback] 强制模拟：重启后版本校验不匹配，进入回滚分支"
    NEW_VER="9.9.9"
else
    NEW_VER=$(current_version "$FRPC_PATH")
fi
if [ -n "$NEW_VER" ] && [ "$(norm "$NEW_VER")" = "$(norm "$TARGET_VERSION")" ]; then
    log_info "升级成功：frpc 现在为 v${NEW_VER}"
    exit 0
elif [ -z "$NEW_VER" ]; then
    # 解析不到版本：无法确认成功与否，但新二进制已通过可执行性校验，
    # 不盲目回滚（回滚反而可能把刚换上的新版换掉）。提示用户手动确认。
    log_warn "重启后未能解析到 frpc 版本（/usr/bin/frpc --version 输出异常），未做回滚。"
    log_warn "请手动执行: /usr/bin/frpc --version  确认实际版本；若确为 ${TARGET_VERSION} 则升级已成功。"
    log_warn "原始 --version 输出: $("$FRPC_PATH" --version 2>&1 | head -n3)"
    exit 0
else
    log_warn "重启后版本为 ${NEW_VER}（期望 ${TARGET_VERSION}），尝试回滚"
    if [ -f "$BAK" ] && mv "$BAK" "$FRPC_PATH" 2>/dev/null; then
        log_warn "已回滚到旧版本 ${CUR_VER}"
        restart_frpc
    fi
    exit 1
fi
