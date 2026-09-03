#!/bin/sh
set -eu

REPO="slobys/openclash-auto-installer"
BRANCH="main"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
BASE_URL="${OPENCLASH_AUTO_BASE_URL:-$DEFAULT_BASE_URL}"
RESOLVED_BASE_URL=""
TMP_SCRIPT="/tmp/openclash-menu-action.sh"
NONINTERACTIVE_ACTION=""

# --------------------- 下载加速配置 ---------------------
# GitHub 镜像（留空 = 直连）。可用: https://gh.2026178.xyz / https://ghproxy.net / https://gh-proxy.com
GITHUB_MIRROR="${GITHUB_MIRROR-https://gh.2026178.xyz}"
# Gitee 镜像源（上游推荐的国内入口）
GITEE_BASE_URL="https://gitee.com/naiyou88/openclash-auto-installer/raw/main"
# HTTP/HTTPS 代理，会 export 给子脚本，可加速 GitHub Release / ipk 内核下载
PROXY_URL="${PROXY_URL:-${HTTPS_PROXY:-${https_proxy:-}}}"
# 1 = 启动时自动测速并选择最快下载源
AUTO_SOURCE="0"
# 脚本自身所在目录（优先使用同目录的本地脚本，免下载）
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || printf '.')"

log() {
    printf '%s\n' "==> $*"
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

need_downloader() {
    command -v curl >/dev/null 2>&1 && return 0
    command -v wget >/dev/null 2>&1 && return 0
    die "缺少 curl 或 wget，无法下载脚本"
}

# 把 github / raw / api 地址改写成镜像地址；未配置镜像时原样返回
mirror_rewrite() {
    MIRROR_IN="$1"
    if [ -z "$GITHUB_MIRROR" ]; then
        printf '%s' "$MIRROR_IN"
        return 0
    fi
    M="$(printf '%s' "$GITHUB_MIRROR" | sed 's:/*$::')"
    printf '%s' "$MIRROR_IN" | sed \
        -e "s#^https://raw.githubusercontent.com#${M}/raw#g" \
        -e "s#^https://api.github.com#${M}/api#g" \
        -e "s#^https://github.com#${M}#g" \
        -e "s#^https://objects.githubusercontent.com#${M}#g"
}

# 输出候选地址：镜像优先，直连兜底
url_candidates() {
    CAND_IN="$1"
    CAND_MIRROR="$(mirror_rewrite "$CAND_IN")"
    if [ -n "$GITHUB_MIRROR" ] && [ "$CAND_MIRROR" != "$CAND_IN" ]; then
        printf '%s\n%s\n' "$CAND_MIRROR" "$CAND_IN"
    else
        printf '%s\n' "$CAND_IN"
    fi
}

# 镜像失效时常常返回 HTML 错误页，这里做一次内容校验
looks_like_html() {
    head -c 256 "$1" 2>/dev/null | grep -qi '<html\|<!doctype\|<head'
}

download_file() {
    URL="$1"
    OUT="$2"
    DL_USED_URL=""

    for CAND in $(url_candidates "$URL"); do
        rm -f "$OUT"

        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout 8 --max-time 180 "$CAND" -o "$OUT" 2>/dev/null ||
                curl -kfsSL --retry 1 --connect-timeout 8 --max-time 180 "$CAND" -o "$OUT" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q --tries=2 --timeout=15 -O "$OUT" "$CAND" 2>/dev/null ||
                wget --no-check-certificate -q --tries=1 --timeout=15 -O "$OUT" "$CAND" 2>/dev/null || true
        fi

        if [ -s "$OUT" ] && ! looks_like_html "$OUT"; then
            DL_USED_URL="$CAND"
            return 0
        fi

        if [ "$CAND" != "$URL" ]; then
            printf '%s\n' "[WARN] 镜像不可用，回退直连: $CAND" >&2
        fi
    done

    return 1
}

# 代理导出后子脚本（install.sh / passwall.sh 等）里的 curl/wget 同样走代理
apply_download_proxy() {
    if [ -z "$PROXY_URL" ]; then
        return 0
    fi
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
    log "已启用下载代理（子脚本同样生效）: $PROXY_URL"
}

# 返回耗时秒数，失败返回非空退出码
speed_test_url() {
    SPEED_URL="$1"
    if command -v curl >/dev/null 2>&1; then
        SPEED_R="$(curl -fsSL -o /dev/null -w '%{time_total}' --connect-timeout 6 --max-time 30 "$SPEED_URL" 2>/dev/null || true)"
        case "$SPEED_R" in
            ''|*[!0-9.]*) return 1 ;;
        esac
        printf '%s' "$SPEED_R"
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        SPEED_T0="$(date +%s)"
        if wget -q -O /dev/null --tries=1 --timeout=20 "$SPEED_URL" 2>/dev/null; then
            SPEED_T1="$(date +%s)"
            printf '%s' "$((SPEED_T1 - SPEED_T0 + 1))"
            return 0
        fi
    fi
    return 1
}

num_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a < b)}'
}

auto_pick_source() {
    log "正在测速，选择最快下载源..."
    SRC_LIST="/tmp/openclash-menu-sources.txt"
    : >"$SRC_LIST"
    printf '%s\n' "GitHub 直连|$DEFAULT_BASE_URL" >>"$SRC_LIST"

    MIRROR_BASE="$(mirror_rewrite "$DEFAULT_BASE_URL")"
    if [ "$MIRROR_BASE" != "$DEFAULT_BASE_URL" ]; then
        printf '%s\n' "GitHub 镜像|$MIRROR_BASE" >>"$SRC_LIST"
    fi
    printf '%s\n' "Gitee 镜像|$GITEE_BASE_URL" >>"$SRC_LIST"
    if [ "${OPENCLASH_AUTO_BASE_URL:-}" != "" ]; then
        printf '%s\n' "自定义源|$OPENCLASH_AUTO_BASE_URL" >>"$SRC_LIST"
    fi

    BEST_NAME=""
    BEST_TIME=""
    BEST_BASE=""

    while IFS='|' read -r SRC_NAME SRC_BASE; do
        [ -n "$SRC_BASE" ] || continue
        SRC_T="$(speed_test_url "$SRC_BASE/menu.sh" || true)"
        if [ -z "$SRC_T" ]; then
            printf '%s\n' "    $SRC_NAME: 不可用"
            continue
        fi
        printf '%s\n' "    $SRC_NAME: ${SRC_T}s"
        if [ -z "$BEST_TIME" ] || num_lt "$SRC_T" "$BEST_TIME"; then
            BEST_TIME="$SRC_T"
            BEST_NAME="$SRC_NAME"
            BEST_BASE="$SRC_BASE"
        fi
    done <"$SRC_LIST"
    rm -f "$SRC_LIST"

    [ -n "$BEST_BASE" ] || die "所有下载源均不可用，请检查网络或手动指定 --mirror / --gitee"
    log "已选择最快下载源: $BEST_NAME -> $BEST_BASE"
    BASE_URL="$BEST_BASE"
    RESOLVED_BASE_URL="$BEST_BASE"
}

usage() {
    cat <<'EOF_USAGE'
用法:
  sh menu.sh
  sh menu.sh --check-all-updates
  sh menu.sh --check-updates
  sh menu.sh --check-update-openclash
  sh menu.sh --check-update-passwall
  sh menu.sh --check-update-passwall2
  sh menu.sh --check-update-nikki
  sh menu.sh --check-update-smartdns
  sh menu.sh --check-update-mosdns
  sh menu.sh --check-update-daed
  sh menu.sh --openclash
  sh menu.sh --openclash-check-update
  sh menu.sh --openclash-plugin-only
  sh menu.sh --openclash-core-only
  sh menu.sh --openclash-meta-core
  sh menu.sh --openclash-smart-core
  sh menu.sh --passwall
  sh menu.sh --passwall2
  sh menu.sh --nikki
  sh menu.sh --smartdns
  sh menu.sh --mosdns
  sh menu.sh --daed
  sh menu.sh --uninstall-passwall
  sh menu.sh --uninstall-passwall-deep
  sh menu.sh --uninstall-passwall2
  sh menu.sh --uninstall-passwall2-deep
  sh menu.sh --uninstall-nikki
  sh menu.sh --uninstall-smartdns
  sh menu.sh --uninstall-mosdns
  sh menu.sh --uninstall-daed
  sh menu.sh --uninstall-openclash

下载加速:
  --fast               启动时自动测速并选择最快下载源（GitHub 直连 / 镜像 / Gitee）
  --gitee              使用 Gitee 镜像源
  --mirror URL         指定 GitHub 镜像，例如 --mirror https://ghproxy.net
  --no-mirror          关闭镜像，全部直连
  --proxy URL          设置下载代理，例如 --proxy http://192.168.1.1:7890
                       代理会同时透传给子脚本，可加速 Release / ipk 下载

环境变量:
  GITHUB_MIRROR        默认 https://gh.2026178.xyz，设为空表示直连
  PROXY_URL / HTTPS_PROXY   下载代理
  OPENCLASH_AUTO_BASE_URL   自定义脚本源（优先级最高）

说明:
  不带参数时进入交互菜单
  带参数时直接执行对应动作，适合非交互环境
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --openclash)
                NONINTERACTIVE_ACTION="openclash"
                ;;
            --check-all-updates)
                NONINTERACTIVE_ACTION="check-all-updates"
                ;;
            --check-updates)
                NONINTERACTIVE_ACTION="check-updates"
                ;;
            --check-update-openclash)
                NONINTERACTIVE_ACTION="check-update-openclash"
                ;;
            --check-update-passwall)
                NONINTERACTIVE_ACTION="check-update-passwall"
                ;;
            --check-update-passwall2)
                NONINTERACTIVE_ACTION="check-update-passwall2"
                ;;
            --check-update-nikki)
                NONINTERACTIVE_ACTION="check-update-nikki"
                ;;
            --check-update-smartdns)
                NONINTERACTIVE_ACTION="check-update-smartdns"
                ;;
            --check-update-mosdns)
                NONINTERACTIVE_ACTION="check-update-mosdns"
                ;;
            --check-update-daed)
                NONINTERACTIVE_ACTION="check-update-daed"
                ;;
            --openclash-check-update)
                NONINTERACTIVE_ACTION="openclash-check-update"
                ;;
            --openclash-plugin-only)
                NONINTERACTIVE_ACTION="openclash-plugin-only"
                ;;
            --openclash-core-only)
                NONINTERACTIVE_ACTION="openclash-core-only"
                ;;
            --openclash-meta-core)
                NONINTERACTIVE_ACTION="openclash-meta-core"
                ;;
            --openclash-smart-core)
                NONINTERACTIVE_ACTION="openclash-smart-core"
                ;;
            --passwall)
                NONINTERACTIVE_ACTION="passwall"
                ;;
            --passwall2)
                NONINTERACTIVE_ACTION="passwall2"
                ;;
            --nikki)
                NONINTERACTIVE_ACTION="nikki"
                ;;
            --smartdns)
                NONINTERACTIVE_ACTION="smartdns"
                ;;
            --mosdns)
                NONINTERACTIVE_ACTION="mosdns"
                ;;
            --daed)
                NONINTERACTIVE_ACTION="daed"
                ;;
            --uninstall-passwall)
                NONINTERACTIVE_ACTION="uninstall-passwall"
                ;;
            --uninstall-passwall-deep)
                NONINTERACTIVE_ACTION="uninstall-passwall-deep"
                ;;
            --uninstall-passwall2)
                NONINTERACTIVE_ACTION="uninstall-passwall2"
                ;;
            --uninstall-passwall2-deep)
                NONINTERACTIVE_ACTION="uninstall-passwall2-deep"
                ;;
            --uninstall-nikki)
                NONINTERACTIVE_ACTION="uninstall-nikki"
                ;;
            --uninstall-smartdns)
                NONINTERACTIVE_ACTION="uninstall-smartdns"
                ;;
            --uninstall-mosdns)
                NONINTERACTIVE_ACTION="uninstall-mosdns"
                ;;
            --uninstall-daed)
                NONINTERACTIVE_ACTION="uninstall-daed"
                ;;
            --uninstall-openclash)
                NONINTERACTIVE_ACTION="uninstall-openclash"
                ;;
            --fast|--auto-source)
                AUTO_SOURCE="1"
                ;;
            --gitee)
                BASE_URL="$GITEE_BASE_URL"
                RESOLVED_BASE_URL="$GITEE_BASE_URL"
                ;;
            --mirror)
                [ "$#" -ge 2 ] || die "--mirror 需要一个镜像地址参数"
                GITHUB_MIRROR="$2"
                shift
                ;;
            --mirror=*)
                GITHUB_MIRROR="${1#--mirror=}"
                ;;
            --no-mirror)
                GITHUB_MIRROR=""
                ;;
            --proxy)
                [ "$#" -ge 2 ] || die "--proxy 需要一个代理地址参数"
                PROXY_URL="$2"
                shift
                ;;
            --proxy=*)
                PROXY_URL="${1#--proxy=}"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
        shift
    done
}

resolve_base_url() {
    if [ -n "$RESOLVED_BASE_URL" ]; then
        printf '%s' "$RESOLVED_BASE_URL"
        return 0
    fi

    if [ "${OPENCLASH_AUTO_BASE_URL:-}" != "" ]; then
        RESOLVED_BASE_URL="$BASE_URL"
        printf '%s' "$RESOLVED_BASE_URL"
        return 0
    fi

    COMMIT_JSON="/tmp/openclash-menu-commit.json"
    rm -f "$COMMIT_JSON"
    LATEST_SHA=""
    if download_file "https://api.github.com/repos/$REPO/commits/$BRANCH" "$COMMIT_JSON"; then
        LATEST_SHA="$(sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$COMMIT_JSON" | head -n1 || true)"
        rm -f "$COMMIT_JSON"
    fi
    if [ -n "$LATEST_SHA" ]; then
        RESOLVED_BASE_URL="https://raw.githubusercontent.com/$REPO/$LATEST_SHA"
    else
        RESOLVED_BASE_URL="$BASE_URL"
    fi

    printf '%s' "$RESOLVED_BASE_URL"
}

download_and_run() {
    SCRIPT_NAME="$1"
    shift || true
    
    # 优先使用本地脚本（脚本同目录 / scripts 子目录 / 当前目录），完全免下载
    for LOCAL_SCRIPT in \
        "$SELF_DIR/scripts/$SCRIPT_NAME" \
        "$SELF_DIR/$SCRIPT_NAME" \
        "$SELF_DIR/$SCRIPT_NAME-smart.sh" \
        "scripts/$SCRIPT_NAME" \
        "$SCRIPT_NAME" \
        "$SCRIPT_NAME-smart.sh"; do
        if [ -f "$LOCAL_SCRIPT" ]; then
            log "使用本地脚本: $LOCAL_SCRIPT"
            sh "$LOCAL_SCRIPT" "$@"
            return
        fi
    done

    URL="$(resolve_base_url)/$SCRIPT_NAME"

    log "下载脚本: $URL"
    if download_file "$URL" "$TMP_SCRIPT"; then
        if [ -n "$DL_USED_URL" ] && [ "$DL_USED_URL" != "$URL" ]; then
            log "已通过镜像下载: $DL_USED_URL"
        fi
    else
        die "下载脚本失败: $SCRIPT_NAME（可尝试 --gitee / --mirror 指定镜像，或 --proxy 设置代理）"
    fi
    chmod +x "$TMP_SCRIPT"
    sh "$TMP_SCRIPT" "$@"
}

detect_pm() {
    if command -v apk >/dev/null 2>&1; then
        printf 'apk'
    elif command -v opkg >/dev/null 2>&1; then
        printf 'opkg'
    fi
}

confirm_default_yes() {
    if [ ! -r /dev/tty ]; then
        return 0
    fi
    printf '%s (y/n): ' "$1" >/dev/tty
    read_from_tty _confirm_answer
    case "$_confirm_answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_default_no() {
    if [ ! -r /dev/tty ]; then
        return 1
    fi
    printf '%s (y/n): ' "$1" >/dev/tty
    read_from_tty _confirm_answer
    case "$_confirm_answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

rm_rf_glob() {
    for _rm_p in "$@"; do
        rm -rf $_rm_p >/dev/null 2>&1 || true
    done
}

deep_uninstall() {
    FLAVOR="${1:-passwall}"
    case "$FLAVOR" in
        passwall)
            DEEP_BASE_PKGS="luci-app-passwall luci-i18n-passwall-zh-cn xray-core sing-box ipt2socks chinadns-ng brook trojan-plus trojan v2ray-plugin v2ray-core micrologger"
            ;;
        passwall2)
            DEEP_BASE_PKGS="luci-app-passwall2 luci-i18n-passwall2-zh-cn sing-box xray-core ipt2socks chinadns-ng"
            ;;
        *)
            die "不支持的深度卸载目标: $FLAVOR"
            ;;
    esac
    DEEP_FUZZY_RE='xray|sing-box|trojan|v2ray|brook|hysteria|naive|tuic|shadowsocks|ipt2socks|chinadns'

    DEEP_OTHER="passwall2"
    if [ "$FLAVOR" = "passwall2" ]; then
        DEEP_OTHER="passwall"
    fi
    if [ -f "/etc/config/$DEEP_OTHER" ] || [ -d "/usr/share/$DEEP_OTHER" ]; then
        printf '%s\n' "[WARN] 检测到 $DEEP_OTHER 仍在使用，深度清理可能移除其共用核心，必要时请重新安装 $DEEP_OTHER"
    fi

    printf '\n'
    log "======== 深度卸载 $FLAVOR ========"
    if ! confirm_default_yes "[?] 深度卸载会一并清理 xray / sing-box 等共用核心及全部配置残留，是否继续"; then
        log "已取消深度卸载"
        return 0
    fi

    # 1. 停止并禁用服务
    if [ -x "/etc/init.d/$FLAVOR" ]; then
        log "停止并禁用服务: $FLAVOR"
        "/etc/init.d/$FLAVOR" disable >/dev/null 2>&1 || true
        "/etc/init.d/$FLAVOR" stop >/dev/null 2>&1 || true
    fi

    # 2. 卸载软件包（含不再需要的依赖）
    DEEP_PM="$(detect_pm)"
    if [ -z "$DEEP_PM" ]; then
        printf '%s\n' '[WARN] 未检测到 apk / opkg，跳过软件包卸载，仅清理文件残留'
    else
        log "使用 $DEEP_PM 卸载 $FLAVOR 及其核心依赖"
        if [ "$DEEP_PM" = "apk" ]; then
            apk del $DEEP_BASE_PKGS 2>&1 | sed 's/^/    /' || true
            DEEP_REM_PKGS="$(apk info 2>/dev/null | grep -E "$DEEP_FUZZY_RE" || true)"
            if [ -n "$DEEP_REM_PKGS" ]; then
                log "模糊清理残留内核组件: $(printf '%s' "$DEEP_REM_PKGS" | tr '\n' ' ')"
                apk del $DEEP_REM_PKGS 2>&1 | sed 's/^/    /' || true
            fi
        else
            opkg remove $DEEP_BASE_PKGS 2>&1 | sed 's/^/    /' || true
            DEEP_REM_PKGS="$(opkg list-installed 2>/dev/null | awk '{print $1}' | grep -E "$DEEP_FUZZY_RE" || true)"
            if [ -n "$DEEP_REM_PKGS" ]; then
                log "模糊清理残留内核组件: $(printf '%s' "$DEEP_REM_PKGS" | tr '\n' ' ')"
                opkg remove $DEEP_REM_PKGS 2>&1 | sed 's/^/    /' || true
            fi
        fi
    fi

    # 3. 清理防火墙 / nft / ipset 残留
    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/firewall ]; then
        uci -q delete "firewall.$FLAVOR" || true
        DEEP_IDX=0
        while uci -q get "firewall.@include[$DEEP_IDX]" >/dev/null 2>&1; do
            DEEP_PATH="$(uci -q get "firewall.@include[$DEEP_IDX].path" || true)"
            case "$DEEP_PATH" in
                *"$FLAVOR"*)
                    uci -q delete "firewall.@include[$DEEP_IDX]" && continue || DEEP_IDX=$((DEEP_IDX + 1))
                    ;;
                *)
                    DEEP_IDX=$((DEEP_IDX + 1))
                    ;;
            esac
        done
        uci -q commit firewall || true
        log "已清理 firewall 中残留的 $FLAVOR 引用"
    fi

    if command -v nft >/dev/null 2>&1; then
        for fam in inet ip ip6; do
            nft delete table $fam "$FLAVOR" >/dev/null 2>&1 || true
        done
    fi

    if command -v ipset >/dev/null 2>&1; then
        ipset list -n 2>/dev/null | grep -i "$FLAVOR" | while read -r _set_name; do
            ipset destroy "$_set_name" >/dev/null 2>&1 || true
        done
    fi

    # 4. 清理 cron 定时任务
    if [ -f /etc/crontabs/root ] && grep -qi "$FLAVOR" /etc/crontabs/root 2>/dev/null; then
        grep -v -i "$FLAVOR" /etc/crontabs/root >/tmp/crontab-clean.tmp 2>/dev/null && mv /tmp/crontab-clean.tmp /etc/crontabs/root
        rm -f /tmp/crontab-clean.tmp
        /etc/init.d/cron restart >/dev/null 2>&1 || true
        log "已清理 cron 中的 $FLAVOR 定时任务"
    fi

    # 5. 删除残留文件与配置
    log "清理残留文件与配置"
    rm_rf_glob \
        "/etc/config/$FLAVOR" \
        "/etc/config/${FLAVOR}_server" \
        "/etc/$FLAVOR" \
        "/usr/share/$FLAVOR" \
        "/usr/share/${FLAVOR}_server" \
        "/var/etc/$FLAVOR" \
        "/tmp/etc/$FLAVOR" \
        "/etc/init.d/$FLAVOR" \
        "/etc/init.d/${FLAVOR}_server" \
        "/www/luci-static/resources/view/$FLAVOR" \
        "/usr/lib/lua/luci/model/cbi/$FLAVOR" \
        "/usr/lib/lua/luci/view/$FLAVOR" \
        "/usr/lib/lua/luci/i18n/$FLAVOR.*" \
        "/usr/share/luci/menu.d/luci-app-$FLAVOR.json" \
        "/usr/share/rpcd/acl.d/luci-app-$FLAVOR.json" \
        "/usr/libexec/rpcd/$FLAVOR" \
        "/usr/lib/opkg/info/luci-app-$FLAVOR.*" \
        "/usr/lib/opkg/info/luci-i18n-$FLAVOR-zh-cn.*" \
        "/tmp/log/$FLAVOR.log" \
        "/var/log/$FLAVOR" \
        "/tmp/dnsmasq.d/$FLAVOR" \
        "/etc/dnsmasq.d/$FLAVOR" \
        "/tmp/etc/dnsmasq.d/$FLAVOR" \
        "/var/etc/dnsmasq.d/$FLAVOR" \
        "/var/lock/$FLAVOR*" \
        "/var/run/$FLAVOR*" \
        "/etc/uci-defaults/*$FLAVOR*" \
        "/etc/hotplug.d/*/*$FLAVOR*" \
        "/etc/nftables.d/*$FLAVOR*"

    log "深度卸载 $FLAVOR 完成"
    if confirm_default_no "[?] 是否立即重启路由器使网络更改生效"; then
        log "正在重启路由器..."
        reboot || true
    else
        log "已跳过重启，建议稍后手动执行 reboot"
    fi
}

show_menu() {
    cat <<'EOF_MENU'
================ 代理插件管理菜单 ================
1. 检查插件更新
2. 安装插件
3. 卸载插件
4. 下载加速设置
0. 退出
==================================================
EOF_MENU
}

show_accel_menu() {
    cat <<EOF_ACCEL
================ 下载加速设置 ================
当前镜像: ${GITHUB_MIRROR:-未启用（直连）}
当前代理: ${PROXY_URL:-未设置}
当前源  : ${RESOLVED_BASE_URL:-$BASE_URL}
1. 自动测速并选择最快下载源（推荐）
2. 使用 GitHub 镜像加速
3. 使用 Gitee 镜像源
4. 使用 GitHub 直连（关闭加速）
5. 设置 HTTP/HTTPS 代理（子脚本同样生效）
6. 清除代理
0. 返回上一级
==============================================
EOF_ACCEL
}

run_accel_menu() {
    while true; do
        show_accel_menu
        printf '请输入选项 [0-6]: ' >/dev/tty
        read_from_tty subchoice
        case "$subchoice" in
            1)
                auto_pick_source
                ;;
            2)
                if [ -z "$GITHUB_MIRROR" ]; then
                    GITHUB_MIRROR="https://gh.2026178.xyz"
                fi
                BASE_URL="$DEFAULT_BASE_URL"
                RESOLVED_BASE_URL=""
                log "已启用 GitHub 镜像: $GITHUB_MIRROR"
                ;;
            3)
                GITHUB_MIRROR=""
                BASE_URL="$GITEE_BASE_URL"
                RESOLVED_BASE_URL="$GITEE_BASE_URL"
                log "已切换到 Gitee 源: $GITEE_BASE_URL"
                ;;
            4)
                GITHUB_MIRROR=""
                BASE_URL="$DEFAULT_BASE_URL"
                RESOLVED_BASE_URL=""
                log "已关闭加速，使用 GitHub 直连"
                ;;
            5)
                printf '请输入代理地址 (如 http://192.168.1.1:7890): ' >/dev/tty
                read_from_tty _proxy_in
                if [ -n "$_proxy_in" ]; then
                    PROXY_URL="$_proxy_in"
                    apply_download_proxy
                fi
                ;;
            6)
                PROXY_URL=""
                unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
                log "已清除代理"
                ;;
            0)
                return 0
                ;;
            *)
                printf '%s\n' '[WARN] 无效选项，请重新输入'
                ;;
        esac
        printf '\n按回车键返回下载加速设置菜单...' >/dev/tty
        read_from_tty _subdummy
        printf '\n'
    done
}

show_install_menu() {
    cat <<'EOF_INSTALL_MENU'
================ 安装插件 ================
1. 安装 / 更新 OpenClash（自动识别 Meta / Smart）
2. 只更新 OpenClash 插件
3. 只安装 OpenClash 核心（自动识别 Meta / Smart）
4. 只安装 OpenClash 普通 Meta 内核
5. 只安装 OpenClash Smart Meta 内核
6. 安装 / 更新 PassWall
7. 安装 / 更新 PassWall2
8. 安装 / 更新 Nikki
9. 安装 / 更新 SmartDNS
10. 安装 / 更新 MosDNS
11. 安装 / 更新 daed
0. 返回上一级
==========================================
EOF_INSTALL_MENU
}

show_uninstall_menu() {
    cat <<'EOF_UNINSTALL_MENU'
================ 卸载插件 ================
1. 卸载 PassWall（含深度清理依赖与残留）
2. 卸载 PassWall2
3. 卸载 Nikki
4. 卸载 SmartDNS
5. 卸载 MosDNS
6. 卸载 OpenClash
7. 卸载 daed
8. 仅深度清理 PassWall 残留
9. 仅深度清理 PassWall2 残留
0. 返回上一级
==========================================
EOF_UNINSTALL_MENU
}

show_check_update_menu() {
    cat <<'EOF_CHECK_MENU'
================ 检查插件更新 ================
1. 检查所有插件
2. 检查 OpenClash
3. 检查 PassWall
4. 检查 PassWall2
5. 检查 Nikki
6. 检查 SmartDNS
7. 检查 MosDNS
8. 检查 daed
0. 返回上一级
==============================================
EOF_CHECK_MENU
}

read_from_tty() {
    if [ -r /dev/tty ]; then
        read -r "$1" </dev/tty
    else
        die "当前环境不可交互，请改用非交互参数模式"
    fi
}

run_action() {
    action="$1"
    case "$action" in
        1|check-updates)
            run_check_update_menu
            SKIP_MAIN_PAUSE="1"
            ;;
        check-all-updates)
            download_and_run check-updates.sh
            ;;
        check-update-openclash)
            download_and_run check-updates.sh --openclash
            ;;
        check-update-passwall)
            download_and_run check-updates.sh --passwall
            ;;
        check-update-passwall2)
            download_and_run check-updates.sh --passwall2
            ;;
        check-update-nikki)
            download_and_run check-updates.sh --nikki
            ;;
        check-update-smartdns)
            download_and_run check-updates.sh --smartdns
            ;;
        check-update-mosdns)
            download_and_run check-updates.sh --mosdns
            ;;
        check-update-daed)
            download_and_run check-updates.sh --daed
            ;;
        2|install-plugins)
            run_install_menu
            SKIP_MAIN_PAUSE="1"
            ;;
        3|uninstall-plugins)
            run_uninstall_menu
            SKIP_MAIN_PAUSE="1"
            ;;
        4|accel)
            run_accel_menu
            SKIP_MAIN_PAUSE="1"
            ;;
        openclash)
            download_and_run install.sh
            ;;
        openclash-check-update)
            download_and_run install.sh --check-update --skip-pkg-update
            ;;
        openclash-plugin-only)
            download_and_run install.sh --plugin-only
            ;;
        openclash-core-only)
            download_and_run install.sh --core-only
            ;;
        openclash-meta-core)
            download_and_run install.sh --core-only --meta-core --skip-pkg-update
            ;;
        openclash-smart-core)
            download_and_run install.sh --core-only --smart-core --skip-pkg-update
            ;;
        passwall)
            download_and_run passwall.sh
            ;;
        passwall2)
            download_and_run passwall2.sh
            ;;
        nikki)
            download_and_run nikki.sh
            ;;
        smartdns)
            download_and_run smartdns.sh
            ;;
        mosdns)
            download_and_run mosdns.sh
            ;;
        daed)
            download_and_run daed.sh
            ;;
        uninstall-passwall)
            if ( download_and_run uninstall.sh passwall --delete-config ); then
                log "标准卸载完成，继续深度清理..."
            else
                log "标准卸载脚本异常结束，继续尝试深度清理..."
            fi
            deep_uninstall passwall
            ;;
        uninstall-passwall-deep)
            deep_uninstall passwall
            ;;
        uninstall-passwall2)
            download_and_run uninstall.sh passwall2 --delete-config
            ;;
        uninstall-passwall2-deep)
            deep_uninstall passwall2
            ;;
        uninstall-nikki)
            download_and_run uninstall.sh nikki --delete-config
            ;;
        uninstall-smartdns)
            download_and_run uninstall.sh smartdns --delete-config
            ;;
        uninstall-mosdns)
            download_and_run uninstall.sh mosdns --delete-config
            ;;
        uninstall-daed)
            download_and_run uninstall.sh daed --delete-config
            ;;
        uninstall-openclash)
            download_and_run uninstall.sh openclash --delete-config
            ;;
        0)
            log "已退出"
            exit 0
            ;;
        *)
            printf '%s\n' '[WARN] 无效选项，请重新输入'
            ;;
    esac
}

run_check_update_menu() {
    subchoice=""
    while true; do
        show_check_update_menu
        printf '请输入选项 [0-8]: ' >/dev/tty
        read_from_tty subchoice
        case "$subchoice" in
            1)
                download_and_run check-updates.sh
                ;;
            2)
                download_and_run check-updates.sh --openclash
                ;;
            3)
                download_and_run check-updates.sh --passwall
                ;;
            4)
                download_and_run check-updates.sh --passwall2
                ;;
            5)
                download_and_run check-updates.sh --nikki
                ;;
            6)
                download_and_run check-updates.sh --smartdns
                ;;
            7)
                download_and_run check-updates.sh --mosdns
                ;;
            8)
                download_and_run check-updates.sh --daed
                ;;
            0)
                return 0
                ;;
            *)
                printf '%s\n' '[WARN] 无效选项，请重新输入'
                ;;
        esac
        printf '\n按回车键返回检查插件更新菜单...' >/dev/tty
        read_from_tty _subdummy
        printf '\n'
    done
}

run_install_menu() {
    while true; do
        show_install_menu
        printf '请输入选项 [0-11]: ' >/dev/tty
        read_from_tty subchoice
        case "$subchoice" in
            1)
                download_and_run install.sh
                ;;
            2)
                download_and_run install.sh --plugin-only
                ;;
            3)
                download_and_run install.sh --core-only
                ;;
            4)
                download_and_run install.sh --core-only --meta-core --skip-pkg-update
                ;;
            5)
                download_and_run install.sh --core-only --smart-core --skip-pkg-update
                ;;
            6)
                download_and_run passwall.sh
                ;;
            7)
                download_and_run passwall2.sh
                ;;
            8)
                download_and_run nikki.sh
                ;;
            9)
                download_and_run smartdns.sh
                ;;
            10)
                download_and_run mosdns.sh
                ;;
            11)
                download_and_run daed.sh
                ;;
            0)
                return 0
                ;;
            *)
                printf '%s\n' '[WARN] 无效选项，请重新输入'
                ;;
        esac
        printf '\n按回车键返回安装插件菜单...' >/dev/tty
        read_from_tty _subdummy
        printf '\n'
    done
}

run_uninstall_menu() {
    while true; do
        show_uninstall_menu
        printf '请输入选项 [0-9]: ' >/dev/tty
        read_from_tty subchoice
        case "$subchoice" in
            1)
                if ( download_and_run uninstall.sh passwall --delete-config ); then
                    log "标准卸载完成，继续深度清理..."
                else
                    log "标准卸载脚本异常结束，继续尝试深度清理..."
                fi
                deep_uninstall passwall
                ;;
            2)
                download_and_run uninstall.sh passwall2 --delete-config
                ;;
            3)
                download_and_run uninstall.sh nikki --delete-config
                ;;
            4)
                download_and_run uninstall.sh smartdns --delete-config
                ;;
            5)
                download_and_run uninstall.sh mosdns --delete-config
                ;;
            6)
                download_and_run uninstall.sh openclash --delete-config
                ;;
            7)
                download_and_run uninstall.sh daed --delete-config
                ;;
            8)
                deep_uninstall passwall
                ;;
            9)
                deep_uninstall passwall2
                ;;
            0)
                return 0
                ;;
            *)
                printf '%s\n' '[WARN] 无效选项，请重新输入'
                ;;
        esac
        printf '\n按回车键返回卸载插件菜单...' >/dev/tty
        read_from_tty _subdummy
        printf '\n'
    done
}

main() {
    parse_args "$@"
    need_downloader
    choice=""

    apply_download_proxy
    if [ "$AUTO_SOURCE" = "1" ]; then
        auto_pick_source
    fi

    if [ -n "$NONINTERACTIVE_ACTION" ]; then
        run_action "$NONINTERACTIVE_ACTION"
        exit 0
    fi

    while true; do
        show_menu
        printf '请输入选项 [0-4]: ' >/dev/tty
        read_from_tty choice
        SKIP_MAIN_PAUSE="0"
        run_action "$choice"
        if [ "$SKIP_MAIN_PAUSE" != "1" ]; then
            printf '\n按回车键返回菜单...' >/dev/tty
            read_from_tty _dummy
            printf '\n'
        fi
    done
}

main "$@"