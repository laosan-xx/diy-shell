#!/bin/sh
# os-update.sh —— OpenWrt 在线系统更新脚本 (修复版)
# 修复: awk 解析 GitHub API JSON 时 size 字段错位导致 sysupgrade 被误杀
#
# 用法:
#   sh os-update.sh          交互式: 检测 -> 选固件 -> 下载 -> 确认刷写
#   sh os-update.sh -y       跳过确认直接下载并刷写
#   sh os-update.sh -d       只检测并打印可用固件, 不下载不刷写

set -e

FORCE=0
DETECT_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y) FORCE=1 ;;
        -d) DETECT_ONLY=1 ;;
        *)  echo "未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-https://gh.2026178.xyz}"
QUALCOMMAX_REPO="https://gh.2026178.xyz/api/repos/laosan-xx/OpenWRT-CI-VIKINGYFY"
IPQ60_REPO="$QUALCOMMAX_REPO"
MEDIATEK_REPO="https://gh.2026178.xyz/api/repos/laosan-xx/CloseWRT-CI"
FILOGIC_REPO="$MEDIATEK_REPO"

log()  { echo "[sysupdate] $*"; }
err()  { echo "[sysupdate][ERROR] $*" >&2; }

# ============================================================
# Step 1: 检测平台
# ============================================================
log "步骤 1/5  检测平台 ..."

if [ ! -f /etc/openwrt_release ]; then
    err "无法读取 /etc/openwrt_release, 当前环境可能不是 OpenWrt"
    exit 1
fi

DISTRIB_TARGET=$(grep '^DISTRIB_TARGET=' /etc/openwrt_release | tail -n1 | sed "s/DISTRIB_TARGET=//;s/['\"]//g")
if [ -z "$DISTRIB_TARGET" ]; then
    err "未能从 /etc/openwrt_release 解析 DISTRIB_TARGET"
    exit 1
fi
log "  DISTRIB_TARGET = $DISTRIB_TARGET"

BOARD_NAME=$(ubus call system board 2>/dev/null | sed -n 's/.*"board_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$BOARD_NAME" ]; then
    err "无法通过 ubus 获取 board_name"
    exit 1
fi
BOARD_MODEL=$(echo "$BOARD_NAME" | tr ',' '_')
log "  board_name     = $BOARD_NAME"
log "  board_model    = $BOARD_MODEL"

REPO_API=""
case "$DISTRIB_TARGET" in
    *qualcommax*) REPO_API="$QUALCOMMAX_REPO" ;;
    *ipq60*)      REPO_API="$IPQ60_REPO" ;;
    *mediatek*)   REPO_API="$MEDIATEK_REPO" ;;
    *filogic*)    REPO_API="$FILOGIC_REPO" ;;
esac
if [ -z "$REPO_API" ]; then
    err "未支持的平台: $DISTRIB_TARGET (repoMapping 中无匹配)"
    exit 1
fi
log "  匹配仓库 API  = $REPO_API"

# ============================================================
# Step 2: 获取当前系统版本
# ============================================================
log "步骤 2/5  读取当前系统版本 ..."
SYS_JS="/www/luci-static/resources/view/status/include/10_system.js"
CURRENT_VERSION=""
if [ -f "$SYS_JS" ]; then
    CURRENT_VERSION=$(grep -o 'laosan-[A-Za-z0-9_.-]*' "$SYS_JS" | tail -n1)
fi
if [ -n "$CURRENT_VERSION" ]; then
    log "  当前固件版本 = $CURRENT_VERSION"
else
    log "  未能从 $SYS_JS 解析版本(可能非 laosan 构建), 继续..."
fi

# ============================================================
# Step 3: 获取固件列表 + 解析分支
# ============================================================
log "步骤 3/5  查询 GitHub 发布固件列表 ..."
API_URL="${REPO_API}/releases?per_page=20"

if command -v uclient-fetch >/dev/null 2>&1; then
    FETCH="uclient-fetch -qO -"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO -"
elif command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
else
    err "缺少可用的下载工具 (uclient-fetch/wget/curl)"
    exit 1
fi

RAW=$(eval "$FETCH" "$API_URL" 2>/dev/null) || {
    err "请求 GitHub API 失败: $API_URL"
    err "提示: 路由器直连 GitHub 可能受限; 可设置 DOWNLOAD_PROXY 或自行配置代理"
    exit 1
}

# ---- 修复核心 ----
# 原脚本用 RS="\"browser_download_url\"" 切分 JSON, 但 GitHub API asset 对象
# 字段顺序为 name -> size -> ... -> browser_download_url (最后一个字段),
# 导致 RS 切分后: 块 N 的 URL 属于 asset[N-1], 而块内的 size 属于 asset[N].
# 结果 sysupgrade 固件的 size 被错读为下一个 asset (manifest, ~14KB) 的 size,
# 被 >30MB 规则误杀.
#
# 修复: 保留 RS 不变 (BusyBox awk 兼容), 但不再依赖 size 字段做过滤;
# 改用文件扩展名 .bin 判断是否为固件 (manifest/txt 等非固件文件自然排除).
# 同时去掉 size 输出列, 避免 size 错位导致显示误导.
# 候选列表: 每行 = branch<TAB>name<TAB>url (3 列)
CAND=$(mktemp)
echo "$RAW" | awk -v bm="$BOARD_MODEL" -v dp="$DOWNLOAD_PROXY" -v OFS="\t" '
BEGIN { RS="\"browser_download_url\""; cur_branch="default"; }
{
    blk = $0
    # 1) 若本块含 release 发布名(含 -LAOSAN-), 更新当前 branch
    m = match(blk, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/)
    if (m) {
        nn = substr(blk, RSTART, RLENGTH)
        gsub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", nn)
        gsub(/".*/, "", nn)
        if (nn ~ /-LAOSAN-/) {
            b = nn
            sub(/.*-LAOSAN-/, "", b)   # -> main-26.08.06-...
            sub(/-.*/, "", b)          # -> main
            if (b != "") cur_branch = b
        }
    }
    # 2) 本块开头即为某个 asset 的 browser_download_url
    url = blk
    gsub(/^[^:]*:[[:space:]]*"/, "", url); gsub(/".*/, "", url)
    if (url == "") next
    # 关键: 显示名直接取 URL 的 basename, 与下载地址 100% 同源
    name = url
    sub(/^.*\//, "", name)
    ln = tolower(name)
    # 3) 过滤: 必须含 board_model; 排除 factory / rootfs 等非升级镜像
    if (index(name, bm) == 0) next
    if (index(ln, "factory") > 0) next
    if (index(ln, "rootfs") > 0) next
    # 4) 用 .bin 扩展名过滤掉 manifest/txt 等非固件文件 (替代原 size>30MB 判断)
    if (index(ln, ".bin") == 0) next
    # 5) 重写下载地址到代理, 输出
    dl = url
    sub(/^https:\/\/github.com\//, dp "/", dl)
    print cur_branch, name, dl
}
' | sort -ru > "$CAND"

if [ ! -s "$CAND" ]; then
    err "未找到匹配 $BOARD_MODEL 的固件 (排除 factory, 仅 .bin)"
    rm -f "$CAND"
    exit 1
fi

# ---- 步骤 3a: 列出可用分支 ----
BRANCHES=$(mktemp)
awk -F'\t' '{print $1}' "$CAND" | sort -u > "$BRANCHES"
log "  检测到 $(wc -l < "$BRANCHES") 个固件分支:"
i=1
while IFS= read -r b; do
    cnt=$(awk -F'\t' -v x="$b" '$1==x' "$CAND" | wc -l)
    log "    [$i] $b  ($cnt 个固件)"
    i=$((i+1))
done < "$BRANCHES"

if [ "$DETECT_ONLY" = "1" ]; then
    log "仅检测模式, 结束。"
    rm -f "$CAND" "$BRANCHES"
    exit 0
fi

# ---- 选择分支 ----
log "步骤 4/5  选择分支并下载固件 ..."
if [ "$FORCE" = "1" ]; then
    SEL_BRANCH=$(sed -n '1p' "$BRANCHES")
else
    RB=1
    if [ -t 0 ] || [ -c /dev/tty ]; then
        printf "请输入分支序号 [1]: " >/dev/tty
        read -r RB </dev/tty
        RB=${RB:-1}
    fi
    case "$RB" in
        ''|*[!0-9]*) RB=1 ;;
    esac
    SEL_BRANCH=$(sed -n "${RB}p" "$BRANCHES")
fi
if [ -z "$SEL_BRANCH" ]; then
    err "无效分支序号: $RB"
    rm -f "$CAND" "$BRANCHES"
    exit 1
fi
log "  已选分支: $SEL_BRANCH"

# 该分支下的固件文件
FILES=$(mktemp)
awk -F'\t' -v x="$SEL_BRANCH" '$1==x' "$CAND" > "$FILES"
log "  该分支可用固件:"
j=1
while IFS=$(printf '\t') read -r _br nm dl; do
    log "    [$j] $nm"
    j=$((j+1))
done < "$FILES"

if [ "$FORCE" = "1" ]; then
    CHOICE=1
else
    printf "请输入要下载的固件序号 [1]: " >/dev/tty
    read -r REPLY_CHOICE </dev/tty
    CHOICE=${REPLY_CHOICE:-1}
fi

SEL_LINE=$(sed -n "${CHOICE}p" "$FILES" 2>/dev/null)
if [ -z "$SEL_LINE" ]; then
    err "无效序号: $CHOICE"
    rm -f "$CAND" "$BRANCHES" "$FILES"
    exit 1
fi
SEL_NAME=$(echo "$SEL_LINE" | cut -f2)
SEL_URL=$(echo "$SEL_LINE"  | cut -f3)
DEST="/tmp/$SEL_NAME"

log "  已选择: $SEL_NAME"

# 下载 (带进度显示)
if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -O "$DEST" "$SEL_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$DEST" "$SEL_URL"
elif command -v curl >/dev/null 2>&1; then
    curl -fL -o "$DEST" "$SEL_URL"
fi

if [ ! -s "$DEST" ]; then
    err "下载失败或文件为空: $DEST"
    rm -f "$DEST" "$CAND" "$BRANCHES" "$FILES"
    exit 1
fi
log "  下载完成: $(ls -lh "$DEST" | awk '{print $5}')"
rm -f "$CAND" "$BRANCHES" "$FILES"

# ============================================================
# Step 5: 刷写
# ============================================================
log "步骤 5/5  刷写固件 (sysupgrade -n) ..."
log "  -n 参数: 不保留配置。如需保留配置请改用不带 -n 的 sysupgrade。"

if [ "$FORCE" != "1" ]; then
    printf "确认立即刷写并重启路由器? [y/N] " >/dev/tty
    read -r CONFIRM </dev/tty
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) log "已取消刷写, 固件保留在 $DEST"; exit 0 ;;
    esac
fi

log "系统更新中, 路由器即将重启 ..."
exec sysupgrade -n "$DEST"
