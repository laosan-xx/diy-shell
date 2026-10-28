#!/bin/sh
# desc: IP 质量体检 / 不合格自动换 IP
#
# VPS 换 IP 后的自动体检：换 IP -> 查分 + 代理标记 -> 不合格继续换
# （ip_rotate_check.py 的 shell 版，纯 POSIX sh + busybox，无需 python / jq）
#
# 装在 OpenWrt / VPS 上单独跑，或放进本仓库 wrt/ 由 tmd.sh 菜单拉起：
#   tmd            # 菜单里选 ip_rotate_check.sh（首次需 tmd refresh 刷新列表）
#   tmd run ip_rotate_check.sh
# 无参数且在终端里运行时，会先问换 IP 命令 / 次数 / 是否 deep；
#
# 数据源：
#   1) IPLark 评分   —— 直连 /ipscore（仅本机 IP，机房常被 403）
#                      失败则走 r.jina.ai 渲染 https://iplark.com/<ip>
#   2) ip-api.com    —— proxy / hosting / mobile，免密钥，宽松限速
#   3) proxycheck.io —— proxy / type(Residential|TOR|VPN...) / risk，免费 100 次/天
#                      只在"分数低但 ip-api 没报代理"这种含糊情况下才查，省额度
#
# 判定：
#   * 任一源报 proxy/tor/vpn  -> 直接 ROTATE（这才是硬伤）
#   * 只报 hosting 不算硬伤   -> 机房 IP 本来就 hosting，看分数
#   * 分数 >= pass-line(80)   -> PASS；未达 -> ROTATE
#   * 退出码：0=可用 1=本轮都不合格 2=查询失败
#
# 两层缓存，都会影响"分数新鲜度"：
#   1) r.jina.ai 自己缓存页面：同一 URL 5 分钟内直接回缓存（不同 IP = 不同 URL，
#      所以换 IP 后拿到的是新页面）。要强制回源用 --fresh（带 X-No-Cache: true）。
#   2) 本脚本的本地缓存 ip->分数：默认 6 小时过期，--cache-ttl 0 永不过期，
#      --refresh 忽略本地缓存重查。
#
# 用法：
#   sh ip_rotate_check.sh                        # 交互式（会问你换 IP 方式）
#   # 直接用商家的换 IP 接口（GET，token 在 URL 里）
#   sh ip_rotate_check.sh --rotate-url "http://api.xxx.com/changeip?token=xxx&id=123" -n 6
#   # POST + 鉴权头 + body
#   sh ip_rotate_check.sh --rotate-url "http://api.xxx.com/v1/changeip" \
#       --rotate-method POST --rotate-token "Bearer xxx" --rotate-data "id=123&area=us"
#   # 接口不支持 HTTP（如要走 SSH / 面板命令）
#   sh ip_rotate_check.sh --rotate-cmd "ssh root@nat 'reboot'" -n 6
#   # 记住配置，以后不带参数跑就沿用
#   sh ip_rotate_check.sh --rotate-url "..." --save-conf
#   # 装进 crontab：每天北京时间 04:30 跑（改时间用 --cron-time 07:00）
#   sh ip_rotate_check.sh --rotate-url "..." --cron-install
#   sh ip_rotate_check.sh --cron-print      # 只看看会写成什么样
#   sh ip_rotate_check.sh --cron-remove     # 卸载
#   sh ip_rotate_check.sh --check-ip 1.1.1.1 --deep
#   sh ip_rotate_check.sh --rotate-url "..." -n 6 --log run.jsonl --dry-run
#
# 判断"换完了"只用一个标准（不看接口返回内容，通用所有商家）：
#   接口请求成功（HTTP 2xx / 命令 rc=0）后，每 3 秒探一次出口 IP，
#   只要出口 IP 变了就认为换完 -> 体检新 IP -> 不合格继续换；
#   --wait-change 秒内没变则视为本次没换成功，按当前出口继续判定。
# 出口 IP 用 iplark /ipapi/public/ip，失败退 api.ipify.org。
# 接口本身耗时算在 --rotate-timeout（默认 25s，返回慢就加大）。
#

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

# ------------------------- 参数默认值 -------------------------
ROTATE_CMD=""        # 自定义换 IP 命令（sh -c）
ROTATE_URL=""        # 换 IP 的 HTTP 接口
ROTATE_METHOD="GET"  # GET / POST
ROTATE_TOKEN=""      # 放进 Authorization 头（如 "Bearer xxx" 或裸 token）
ROTATE_DATA=""       # POST body，如 "id=123&area=us"
ROTATE_TIMEOUT=25
ATTEMPTS=5
PASS_LINE=80
HARD_LINE=70
CHECK_IP=""
DEEP=0
NO_PROXYCHECK=0
NO_DIRECT=0
WAIT_CHANGE=60
LOG_FILE=""
DRY_RUN=0
SAVE_CONF=0
JINA_FRESH=0     # 1 = 请求 jina 时带 X-No-Cache，不吃它 5 分钟的页面缓存
CACHE_TTL=21600  # 本地缓存有效期（秒），0 = 永不过期
REFRESH=0        # 1 = 忽略本地缓存，重新查
CRON_MODE=""     # install / remove / print
CRON_TIME=04:30  # 定时时间，按北京时间算
CRON_LOG=""      # cron 输出日志，空=自动挑 /var/log 或 /tmp
CRON_BIN_DIR=""  # 脚本复制目录，空=/usr/local/bin
CACHE_FILE="${IP_ROTATE_CACHE:-}"
CONF_FILE="${IP_ROTATE_CONF:-}"
USE_CONF=1

# 可写的用户目录：$HOME 不可用（OpenWrt 上常为空或 /）时退到 /tmp
writable_home() {
    _h=${HOME:-/root}
    [ "$_h" = "/" ] && _h=/root
    if [ -d "$_h" ] && [ -w "$_h" ]; then
        printf '%s\n' "$_h"
    else
        printf '/tmp\n'
    fi
}

usage() {
    cat <<'EOF'
VPS 换 IP 后的自动体检：换 IP -> 查分 + 代理标记 -> 不合格继续换

数据源：IPLark 评分（直连 /ipscore，失败走 r.jina.ai 渲染）
        ip-api.com（proxy / hosting / mobile，免密钥）
        proxycheck.io（proxy / type / risk，免费 100 次/天，按需才查）

判定：任一源报代理 -> ROTATE；只报 hosting 不算硬伤，看分数；
      分数 >= pass-line 为 PASS，低于 pass-line 为 ROTATE
退出码：0=可用 1=本轮都不合格 2=查询失败

换 IP 两种接法（二选一，也可写进配置文件 ~/.ip_rotate.conf 长期复用）：
  --rotate-url URL   直接调商家的换 IP 接口，如
                     "http://api.xxx.com/changeip?token=xxx&id=123"
  --rotate-cmd CMD   跑任意命令，如 "ssh root@nat 'reboot'"，或本机脚本

怎么判断"换完了"：不看接口返回什么，只看出口 IP。
  接口 2xx / 命令 rc=0 之后，每 3 秒探一次出口 IP，
  变了 -> 体检这个新 IP；--wait-change 内没变 -> 认为没换成功，接着换。

选项：
  --rotate-method M  接口方法 GET(默认) / POST
  --rotate-token S   接口鉴权，放进 Authorization 头
  --rotate-data S    POST body，如 "id=123&area=us" 或 '{"id":123}'
                     （以 { 或 [ 开头按 JSON 发，自动补 Content-Type）
  --rotate-timeout N 接口超时秒数，默认 25
  -n, --attempts N   最多尝试次数，默认 5
  --pass-line N      及格线，默认 80
  --hard-line N      硬伤线，默认 70（低于它直接换）
  --check-ip IP      只查指定 IP，不做轮换
  --deep             总是查 proxycheck（多耗额度）
  --no-proxycheck    完全不查 proxycheck
  --no-direct        跳过 /ipscore 直连，直接走 jina 渲染
  --wait-change N    换 IP 后等新 IP 生效的最长秒数，默认 60
  --log FILE         每次体检结果 + 换 IP 事件追加成 jsonl
  --cache FILE       缓存文件，默认 ~/.ip_rotate_cache.tsv
  --cache-ttl N      本地缓存有效期秒数，默认 21600（6h），0=永不过期
  --refresh          忽略本地缓存，同 IP 也重新查
  --fresh            请求 jina 时带 X-No-Cache（绕过它 5 分钟的页面缓存）
  --conf FILE        配置文件，默认 ~/.ip_rotate.conf（存在即加载）
  --no-conf          忽略配置文件
  --save-conf        把当前参数存进配置文件后退出
  --cron-install     装进 crontab（默认每天北京时间 04:30 跑一次）
  --cron-time HH:MM  定时时间，按北京时间算，默认 04:30
  --cron-log FILE    cron 的输出日志，默认 /var/log/ip_rotate_cron.log
  --cron-bin-dir DIR 脚本复制到哪个目录，默认 /usr/local/bin
  --cron-print       只打印要写入的 crontab 行，不安装
  --cron-remove      删除本脚本的 crontab 条目
  --dry-run          只打印将要执行的换 IP 动作，不真跑
  -h, --help         显示本帮助
EOF
}

# ------------------------- 依赖 -------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# 下载器选择与 tmd.sh 对齐：OpenWrt 一般只有 uclient-fetch，VPS 有 curl
if have curl; then
    FETCHER="curl"
elif have uclient-fetch; then
    FETCHER="uclient-fetch"
elif have wget; then
    FETCHER="wget"
else
    FETCHER=""
fi

# --------------- HTTP（curl / uclient-fetch / wget） ---------------
# http_get <url> <超时秒> [plain|jina|iplark]
# 有自定义头的请求若拿不到内容（个别 busybox/uclient 不支持 --header），
# 自动退回不带头的普通请求，至少还能拿个结果
http_get() {
    _u=$1
    _t=$2
    _p=${3:-plain}
    _out=""
    case "$FETCHER" in
    curl)
        set -- -fsSL --connect-timeout "$_t" -m "$_t" -A "$UA"
        case "$_p" in
        jina)
            set -- "$@" -H "X-Return-Format: text"
            # r.jina.ai 同 URL 5 分钟内会回缓存，要最新数据就带 X-No-Cache
            [ "$JINA_FRESH" = 1 ] && set -- "$@" -H "X-No-Cache: true"
            ;;
        iplark)
            set -- "$@" -H "Referer: https://iplark.com/check" \
                -H "Accept: application/json, text/plain, */*" \
                -H "Sec-Fetch-Dest: empty" -H "Sec-Fetch-Mode: cors" \
                -H "Sec-Fetch-Site: same-origin"
            ;;
        esac
        _out=$(curl "$@" "$_u" 2>/dev/null)
        ;;
    uclient-fetch | wget)
        set -- -q -O - -T "$_t" -U "$UA"
        case "$_p" in
        jina)
            set -- "$@" --header="X-Return-Format: text"
            [ "$JINA_FRESH" = 1 ] && set -- "$@" --header="X-No-Cache: true"
            ;;
        iplark)
            set -- "$@" --header="Referer: https://iplark.com/check" \
                --header="Accept: application/json, text/plain, */*"
            ;;
        esac
        if [ "$FETCHER" = "uclient-fetch" ]; then
            _out=$(uclient-fetch "$@" "$_u" 2>/dev/null)
        else
            _out=$(wget "$@" "$_u" 2>/dev/null)
        fi
        ;;
    *)
        echo "缺少 curl / uclient-fetch / wget，无法联网" >&2
        return 1
        ;;
    esac
    if [ -z "$_out" ] && [ "$_p" != "plain" ]; then
        _out=$(http_get "$_u" "$_t" plain)
    fi
    printf '%s' "$_out"
}

# ------------------------- 换 IP：接口 / 命令 -------------------------
have_rotate() {
    [ -n "$ROTATE_URL" ] || [ -n "$ROTATE_CMD" ]
}

# 调商家的换 IP 接口：GET 直接把参数写在 URL 里，POST 用 ROTATE_DATA
# body 以 { 或 [ 开头时按 JSON 发（自动补 Content-Type），否则按表单发
rotate_api() {
    _to=${ROTATE_TIMEOUT:-25}
    _m=${ROTATE_METHOD:-GET}
    _json=0
    case "$ROTATE_DATA" in
    "{"* | "["*) _json=1 ;;
    esac
    if have curl; then
        set -- -fsSL -m "$_to" -A "$UA"
        [ -n "$ROTATE_TOKEN" ] && set -- "$@" -H "Authorization: $ROTATE_TOKEN"
        [ "$_json" = 1 ] && set -- "$@" -H "Content-Type: application/json"
        [ -n "$ROTATE_DATA" ] && set -- "$@" --data "$ROTATE_DATA"
        [ "$_m" = "POST" ] && set -- "$@" -X POST
        set -- "$@" "$ROTATE_URL"
        curl "$@" 2>&1
    elif have uclient-fetch; then
        set -- -q -O - -T "$_to" -U "$UA"
        [ -n "$ROTATE_TOKEN" ] && set -- "$@" --header="Authorization: $ROTATE_TOKEN"
        [ "$_json" = 1 ] && set -- "$@" --header="Content-Type: application/json"
        [ -n "$ROTATE_DATA" ] && set -- "$@" --post-data="$ROTATE_DATA"
        set -- "$@" "$ROTATE_URL"
        uclient-fetch "$@" 2>&1
    elif have wget; then
        set -- -q -O - -T "$_to" -U "$UA"
        [ -n "$ROTATE_TOKEN" ] && set -- "$@" --header="Authorization: $ROTATE_TOKEN"
        [ "$_json" = 1 ] && set -- "$@" --header="Content-Type: application/json"
        [ -n "$ROTATE_DATA" ] && set -- "$@" --post-data="$ROTATE_DATA"
        set -- "$@" "$ROTATE_URL"
        wget "$@" 2>&1
    else
        echo "缺少 curl / uclient-fetch / wget" >&2
        return 1
    fi
}

# 执行一次换 IP；只要请求/命令成功完成就返回 0
# 刻意不解析返回内容：不同商家返回五花八门（裸 IP / JSON / HTML），
# 统一交给主流程判断"出口 IP 有没有变"更通用
do_rotate() {
    if [ -n "$ROTATE_URL" ]; then
        echo "调用换 IP 接口（$ROTATE_METHOD）：$ROTATE_URL" >&2
        _resp=$(rotate_api)
        _rc=$?
        _resp=$(printf '%s' "$_resp" | tr -d '\r\n' | head -c 200)
        if [ "$_rc" != 0 ]; then
            echo "换 IP 接口调用失败（rc=$_rc）：${_resp:-无响应}" >&2
            return 1
        fi
        echo "接口已返回（rc=0）：${_resp:-<空响应>}" >&2
        return 0
    fi
    if [ -n "$ROTATE_CMD" ]; then
        echo "执行换 IP 命令：$ROTATE_CMD" >&2
        # 命令输出直接透到 stderr，保持交互式命令（如 ssh）可用
        sh -c "$ROTATE_CMD" 1>&2
        _rc=$?
        if [ "$_rc" != 0 ]; then
            echo "换 IP 命令执行失败（rc=$_rc）" >&2
            return 1
        fi
        return 0
    fi
    return 1
}

# 写入配置时用的引号转义（值里可能有空格、引号、$）
conf_quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$`]/\\&/g')"
}

# 把当前设置写成 KEY=VALUE，下次直接复用
save_conf() {
    {
        echo "# ip_rotate_check.sh 配置（脚本生成，可直接编辑）"
        echo "# 换 IP：ROTATE_URL 与 ROTATE_CMD 二选一，都为空表示只体检"
        [ -n "$ROTATE_URL" ] && printf 'ROTATE_URL=%s\n' "$(conf_quote "$ROTATE_URL")"
        [ -n "$ROTATE_METHOD" ] && printf 'ROTATE_METHOD=%s\n' "$(conf_quote "$ROTATE_METHOD")"
        [ -n "$ROTATE_TOKEN" ] && printf 'ROTATE_TOKEN=%s\n' "$(conf_quote "$ROTATE_TOKEN")"
        [ -n "$ROTATE_DATA" ] && printf 'ROTATE_DATA=%s\n' "$(conf_quote "$ROTATE_DATA")"
        [ -n "$ROTATE_CMD" ] && printf 'ROTATE_CMD=%s\n' "$(conf_quote "$ROTATE_CMD")"
        printf 'ATTEMPTS=%s\n' "$ATTEMPTS"
        printf 'PASS_LINE=%s\n' "$PASS_LINE"
        printf 'HARD_LINE=%s\n' "$HARD_LINE"
        printf 'WAIT_CHANGE=%s\n' "$WAIT_CHANGE"
        printf 'CACHE_TTL=%s\n' "$CACHE_TTL"
        printf 'JINA_FRESH=%s\n' "$JINA_FRESH"
        printf 'DEEP=%s\n' "$DEEP"
    } >"$1" && chmod 600 "$1" 2>/dev/null
}

# ------------------------- 定时任务（crontab） -------------------------
# cron 用的是本机时区，这里把"北京时间 HH:MM"换算成本机时间，输出 "HH:MM"
bj_to_local_hm() {
    _hm=${1:-04:30}
    _bh=${_hm%%:*}
    _bm=${_hm##*:}
    case "$_bh" in '' | *[!0-9]*) _bh=4 ;; esac
    case "$_bm" in '' | *[!0-9]*) _bm=30 ;; esac
    _z=$(date +%z 2>/dev/null)
    case "$_z" in
    [-+]????) : ;;
    *) _z="+0000" ;;
    esac
    _sg=1
    case "$_z" in -*) _sg=-1 ;; esac
    _z=$(printf '%s' "$_z" | tr -d '+-')
    _zh=${_z%??}
    _zm=${_z#??}
    _zh=${_zh#0}
    _zm=${_zm#0}
    [ -n "$_zh" ] || _zh=0
    [ -n "$_zm" ] || _zm=0
    _off=$((_sg * (_zh * 60 + _zm)))
    # 北京时间 04:30 落在本机几点：加上（本机偏移 - 北京偏移）
    _local=$(((_bh * 60 + _bm + (_off - 480) + 1440) % 1440))
    printf '%02d:%02d\n' $((_local / 60)) $((_local % 60))
}

# 生成要写进 crontab 的那一行
cron_line() {
    _hm_local=$(bj_to_local_hm "${CRON_TIME:-04:30}")
    _lh=${_hm_local%%:*}
    _lm=${_hm_local##*:}
    _bin=$(cron_bin_path)
    _log=${CRON_LOG:-}
    if [ -z "$_log" ]; then
        if [ -d /var/log ] && [ -w /var/log ]; then
            _log="/var/log/ip_rotate_cron.log"
        else
            _log="/tmp/ip_rotate_cron.log"
        fi
    fi
    [ -n "$CONF_FILE" ] || CONF_FILE="$(writable_home)/.ip_rotate.conf"
    # cron 字段去掉前导 0，最稳
    _lm=${_lm#0}
    _lh=${_lh#0}
    printf '%s %s * * * sh %s --conf %s >> %s 2>&1\n' \
        "$_lm" "$_lh" "$_bin" "$CONF_FILE" "$_log"
}

cron_bin_path() {
    printf '%s/ip_rotate_check.sh\n' "${CRON_BIN_DIR:-/usr/local/bin}"
}

# 把脚本本体复制到稳定路径（从 tmd 的 /tmp 缓存里跑时，$0 是临时文件）
cron_install() {
    if ! have crontab; then
        echo "系统里没有 crontab，装不了定时任务（OpenWrt 需 opkg install cron）" >&2
        return 1
    fi
    _bin=$(cron_bin_path)
    _dir=$(dirname "$_bin")
    mkdir -p "$_dir" 2>/dev/null
    if [ "$(cd "$_dir" 2>/dev/null && pwd)/$(basename "$_bin")" != "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ]; then
        cp -f "$0" "$_bin" 2>/dev/null || {
            echo "复制脚本到 $_bin 失败（试试 sudo / root）" >&2
            return 1
        }
    fi
    chmod +x "$_bin" 2>/dev/null
    _line=$(cron_line)
    # 先把原有条目读进变量，再整体写回（避免读写相同时序问题，也保留别人的任务）
    _old=$(crontab -l 2>/dev/null | grep -v 'ip_rotate_check')
    {
        [ -n "$_old" ] && printf '%s\n' "$_old"
        printf '%s\n' "$_line"
    } | crontab -
    if [ $? != 0 ]; then
        echo "写入 crontab 失败（需要 root 权限）" >&2
        return 1
    fi
    echo "已添加定时任务："
    echo "  $_line"
    echo "  北京时间 ${CRON_TIME:-04:30} = 本机时间 $(bj_to_local_hm "${CRON_TIME:-04:30}")"
    echo "  脚本本体：$_bin"
    return 0
}

cron_remove() {
    if ! have crontab; then
        echo "系统里没有 crontab" >&2
        return 1
    fi
    _all=$(crontab -l 2>/dev/null)
    case "$_all" in
    *ip_rotate_check*)
        _old=$(printf '%s\n' "$_all" | grep -v 'ip_rotate_check')
        if [ -n "$_old" ]; then
            printf '%s\n' "$_old" | crontab -
        else
            printf '' | crontab -
        fi
        echo "已从 crontab 移除 ip_rotate_check 的定时任务。"
        ;;
    *)
        echo "crontab 里没有 ip_rotate_check 的条目，无需移除。"
        ;;
    esac
    return 0
}

is_ip() {
    case "$1" in
    '' | *[!0-9a-fA-F:.]*) return 1 ;;
    esac
    case "$1" in
    *:* | *.*) return 0 ;;
    esac
    return 1
}

# IPv6 的冒号在 URL 里要写成 %3A
url_ip() { printf '%s' "$1" | sed 's/:/%3A/g'; }

# 从扁平的 json 文本里取字段（够用即可，不追求完整解析）
json_str() {
    printf '%s' "$1" | tr -d '\r\n' |
        sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}
json_num() {
    printf '%s' "$1" | tr -d '\r\n' |
        sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([-]*[0-9][0-9]*\).*/\1/p' | head -n 1
}
# 输出 1 / 0 / 空
json_bool() {
    _b=$(printf '%s' "$1" | tr -d '\r\n' |
        sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -n 1)
    case "$_b" in
    true) echo 1 ;;
    false) echo 0 ;;
    *) echo "" ;;
    esac
}

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ------------------------- 取出口 IP -------------------------
current_ip() {
    for _u in "https://iplark.com/ipapi/public/ip" "https://api.ipify.org"; do
        _ip=$(http_get "$_u" 10 | tr -d ' \t\r\n')
        if is_ip "$_ip"; then
            printf '%s\n' "$_ip"
            return 0
        fi
    done
    return 1
}

# ------------------------- 评分 -------------------------
# 直连 /ipscore，只对调用方自己的 IP 有效；机房出口通常 403/404
score_direct() {
    _txt=$(http_get "https://iplark.com/ipscore" 12 iplark)
    [ -n "$_txt" ] || return 1
    _s=$(json_num "$_txt" quality_score)
    [ -n "$_s" ] || return 1
    printf '%s\n' "$_s"
}

# 渲染 https://iplark.com/<ip>，输出 "分数<TAB>备注"
score_via_jina() {
    _url="https://r.jina.ai/https://iplark.com/$(url_ip "$1")"
    _note=""
    _i=0
    while [ "$_i" -lt 3 ]; do
        _txt=$(http_get "$_url" 60 jina)
        if [ -n "$_txt" ]; then
            # 「IP评分」后 60 字节内出现的 NN / 100（页面里常有 "IP评分 99 99/100"
            # 这种重复，所以窗口内允许出现数字）；用 awk 避开 busybox sed 的量词差异
            _s=$(printf '%s' "$_txt" | tr '\n' ' ' | awk '{
                rest = $0
                while (match(rest, /IP评分.{0,60}[0-9]{1,3}[[:space:]]*\/[[:space:]]*100/)) {
                    s = substr(rest, RSTART, RLENGTH)
                    if (match(s, /[0-9]{1,3}[[:space:]]*\/[[:space:]]*100/)) {
                        n = substr(s, RSTART, RLENGTH)
                        sub(/[^0-9].*/, "", n)
                        print n
                        exit
                    }
                    rest = substr(rest, RSTART + RLENGTH)
                }
            }' | head -n 1)
            if [ -n "$_s" ]; then
                printf '%s\t\n' "$_s"
                return 0
            fi
            case "$_txt" in
            *"请求的资源不存在"*)
                printf '\t未收录\n'
                return 0
                ;;
            esac
            _note="无评分字段"
        else
            _note="请求失败"
        fi
        _i=$((_i + 1))
        [ "$_i" -lt 3 ] && sleep $((2 * _i))
    done
    printf '\t%s\n' "$_note"
}

get_score() {
    SCORE=""
    SCORE_NOTE=""
    SCORE_SRC=""
    if [ "$2" = 1 ] && [ "$NO_DIRECT" = 0 ]; then
        SCORE=$(score_direct)
        if [ -n "$SCORE" ]; then
            SCORE_SRC="direct"
            return 0
        fi
    fi
    _r=$(score_via_jina "$1")
    SCORE=$(printf '%s' "$_r" | cut -f1)
    SCORE_NOTE=$(printf '%s' "$_r" | cut -f2)
    SCORE_SRC="jina"
}

# ------------------------- 代理标记 -------------------------
AP_PROXY=0
AP_HOSTING=0
AP_MOBILE=0
AP_ASN=""
AP_ISP=""

ip_api_flags() {
    AP_PROXY=0
    AP_HOSTING=0
    AP_MOBILE=0
    AP_ASN=""
    AP_ISP=""
    _j=$(http_get "http://ip-api.com/json/$(url_ip "$1")?fields=status,country,as,isp,proxy,hosting,mobile" 12)
    [ -n "$_j" ] || return 1
    [ "$(json_str "$_j" status)" = "success" ] || return 1
    AP_PROXY=$(json_bool "$_j" proxy)
    AP_HOSTING=$(json_bool "$_j" hosting)
    AP_MOBILE=$(json_bool "$_j" mobile)
    AP_PROXY=${AP_PROXY:-0}
    AP_HOSTING=${AP_HOSTING:-0}
    AP_MOBILE=${AP_MOBILE:-0}
    AP_ASN=$(json_str "$_j" as)
    AP_ISP=$(json_str "$_j" isp)
    return 0
}

PC_PROXY=0
PC_TYPE=""
PC_RISK=""

# proxycheck.io 免费档：proxy/type/risk；查不到返回 1
proxycheck() {
    PC_PROXY=0
    PC_TYPE=""
    PC_RISK=""
    _j=$(http_get "https://proxycheck.io/v2/$(url_ip "$1")?vpn=1&asn=1&risk=1" 15)
    [ -n "$_j" ] || return 1
    [ "$(json_str "$_j" status)" = "ok" ] || return 1
    # 结果对象以 IP 为键：{"status":"ok","1.1.1.1":{...}}，内部还有嵌套对象，
    # 所以直接从 IP 键处截断到结尾，再从中取字段（这些键在结果对象里各只出现一次）
    _tail=$(printf '%s' "$_j" | tr -d ' \r\n' |
        sed -n 's/.*"'"$1"'":{//p' | head -n 1)
    [ -n "$_tail" ] || return 1
    [ "$(json_str "$_tail" proxy)" = "yes" ] && PC_PROXY=1
    PC_TYPE=$(json_str "$_tail" type)
    PC_RISK=$(json_num "$_tail" risk)
    return 0
}

# ------------------------- 判定 -------------------------
decide() {
    WHY=""
    if [ "$AP_PROXY" = 1 ]; then
        WHY="ip-api 报代理"
    fi
    if [ "$PC_PROXY" = 1 ]; then
        WHY="${WHY:+$WHY；}proxycheck 报 ${PC_TYPE:-代理}"
    fi
    if [ -n "$WHY" ]; then
        VERDICT="ROTATE"
        return 0
    fi
    if [ -z "$SCORE" ]; then
        VERDICT="UNKNOWN"
        WHY="无评分"
        return 0
    fi
    if [ "$SCORE" -ge "$PASS_LINE" ]; then
        VERDICT="PASS"
        return 0
    fi
    if [ "$SCORE" -lt "$HARD_LINE" ]; then
        VERDICT="ROTATE"
        WHY="评分 $SCORE < $HARD_LINE"
        return 0
    fi
    VERDICT="ROTATE"
    WHY="评分 $SCORE 未达 $PASS_LINE"
}

# ip-api 给出的粗分类
ap_tag() {
    if [ "$AP_PROXY" = 1 ]; then
        printf 'proxy'
    elif [ "$AP_HOSTING" = 1 ]; then
        printf 'hosting'
    elif [ "$AP_MOBILE" = 1 ]; then
        printf 'mobile'
    else
        printf 'resi'
    fi
}

# ------------------------- 缓存（TSV） -------------------------
# 列：ip 分数 来源 备注 分类 proxycheck 判定 原因 时间戳
# 同 IP 的声誉会变（洗白/变脏），所以有 TTL；--refresh 可强制重查
cache_get() {
    CACHE_STALE=0
    [ -f "$CACHE_FILE" ] || return 1
    _line=$(awk -F'\t' -v ip="$1" '$1==ip && $2!="" {print; exit}' "$CACHE_FILE" 2>/dev/null)
    [ -n "$_line" ] || return 1
    SCORE=$(printf '%s' "$_line" | cut -f2)
    SCORE_SRC=$(printf '%s' "$_line" | cut -f3)
    SCORE_NOTE=$(printf '%s' "$_line" | cut -f4)
    AP_TAG=$(printf '%s' "$_line" | cut -f5)
    PC_TAG=$(printf '%s' "$_line" | cut -f6)
    VERDICT=$(printf '%s' "$_line" | cut -f7)
    WHY=$(printf '%s' "$_line" | cut -f8)
    _c_ts=$(printf '%s' "$_line" | cut -f9)
    if [ "$REFRESH" = 1 ]; then
        CACHE_STALE=1
        return 1
    fi
    if [ "$CACHE_TTL" -gt 0 ] && [ -n "$_c_ts" ]; then
        if [ $(($(date +%s) - _c_ts)) -gt "$CACHE_TTL" ]; then
            CACHE_STALE=1
            return 1
        fi
    fi
    return 0
}

cache_put() {
    _dir=$(dirname "$CACHE_FILE")
    [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null
    if [ -f "$CACHE_FILE" ]; then
        awk -F'\t' -v ip="$1" '$1!=ip' "$CACHE_FILE" >"$CACHE_FILE.tmp" 2>/dev/null &&
            mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$SCORE" "$SCORE_SRC" "$SCORE_NOTE" "$AP_TAG" "$PC_TAG" \
        "$VERDICT" "$WHY" "$(date +%s)" >>"$CACHE_FILE" 2>/dev/null
}

# ------------------------- 输出 -------------------------
print_head() {
    printf '%-16s %3s  %-6s %-7s %-12s %-6s %s\n' "IP" "分" "来源" "ip-api" "proxycheck" "判定" "原因"
}

print_line() {
    _pfx=$1
    _s="  -"
    [ -n "$SCORE" ] && _s=$(printf '%3d' "$SCORE")
    _tail=${WHY:--}
    [ -n "$SCORE_NOTE" ] && _tail="$_tail ($SCORE_NOTE)"
    [ "$CACHED" = 1 ] && _tail="$_tail [cached]"
    printf '%s%-16s %s  %-6s %-7s %-12s %-6s %s\n' \
        "$_pfx" "$CUR_IP" "$_s" "${SCORE_SRC:--}" "${AP_TAG:--}" "${PC_TAG:--}" \
        "$VERDICT" "$_tail"
}

write_log() {
    [ -n "$LOG_FILE" ] || return 0
    if [ -n "$SCORE" ]; then
        _js=$SCORE
    else
        _js=null
    fi
    printf '{"ip":"%s","score":%s,"src":"%s","note":"%s","tag":"%s","proxycheck":"%s","verdict":"%s","why":"%s","ts":%s,"cached":%s}\n' \
        "$(json_esc "$CUR_IP")" "$_js" "$(json_esc "$SCORE_SRC")" "$(json_esc "$SCORE_NOTE")" \
        "$(json_esc "${AP_TAG:--}")" "$(json_esc "${PC_TAG:--}")" "$VERDICT" \
        "$(json_esc "$WHY")" "$(date +%s)" \
        "$([ "$CACHED" = 1 ] && echo true || echo false)" >>"$LOG_FILE"
}

# 换 IP 动作也进日志，方便事后看"从哪个 IP 换到哪个 IP"
log_event() {
    [ -n "$LOG_FILE" ] || return 0
    printf '{"event":"%s",%s"ts":%s}\n' "$1" "$2" "$(date +%s)" >>"$LOG_FILE"
}

# ------------------------- 单 IP 体检 -------------------------
# check_one <ip> <是否本机 1/0> <前缀>
check_one() {
    CUR_IP=$1
    _self=$2
    _pfx=$3
    SCORE=""
    SCORE_SRC=""
    SCORE_NOTE=""
    AP_TAG=""
    PC_TAG=""
    VERDICT=""
    WHY=""
    CACHED=0

    if cache_get "$CUR_IP"; then
        CACHED=1
    else
        [ "$CACHE_STALE" = 1 ] && echo "缓存过期/强制刷新：$CUR_IP" >&2
        echo "查询中：$CUR_IP ..." >&2
        get_score "$CUR_IP" "$_self"
        ip_api_flags "$CUR_IP"
        AP_TAG=$(ap_tag)
        PC_TAG="-"
        # 分数低但 ip-api 没报代理时才查 proxycheck，省额度
        if [ "$NO_PROXYCHECK" = 0 ]; then
            if [ "$DEEP" = 1 ] || { [ -n "$SCORE" ] && [ "$SCORE" -lt "$PASS_LINE" ] && [ "$AP_PROXY" != 1 ]; }; then
                if proxycheck "$CUR_IP"; then
                    PC_TAG="${PC_TYPE:-?}:${PC_RISK:-?}"
                fi
            fi
        fi
        decide
        cache_put "$CUR_IP"
    fi

    print_line "$_pfx"
    write_log
}

# ------------------------- 参数解析 -------------------------
_noargs=0
[ $# -eq 0 ] && _noargs=1

# 先挑出 --conf FILE / --no-conf，决定要不要加载配置文件（配置里的值可被命令行覆盖）
_prev=""
for _a in "$@"; do
    case "$_prev" in --conf) CONF_FILE=$_a ;; esac
    [ "$_a" = "--no-conf" ] && USE_CONF=0
    _prev=$_a
done
if [ "$USE_CONF" = 1 ]; then
    [ -n "$CONF_FILE" ] || CONF_FILE="$(writable_home)/.ip_rotate.conf"
    if [ -f "$CONF_FILE" ]; then
        # 配置是自家生成的 KEY=VALUE，直接 source
        . "$CONF_FILE"
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
    --rotate-url) ROTATE_URL=$2; shift 2 ;;
    --rotate-method) ROTATE_METHOD=$2; shift 2 ;;
    --rotate-token) ROTATE_TOKEN=$2; shift 2 ;;
    --rotate-data) ROTATE_DATA=$2; shift 2 ;;
    --rotate-timeout) ROTATE_TIMEOUT=$2; shift 2 ;;
    --conf) CONF_FILE=$2; shift 2 ;;
    --no-conf) shift ;;
    --save-conf) SAVE_CONF=1; shift ;;
    --cron-install) CRON_MODE=install; shift ;;
    --cron-remove) CRON_MODE=remove; shift ;;
    --cron-print) CRON_MODE=print; shift ;;
    --cron-time) CRON_TIME=$2; shift 2 ;;
    --cron-log) CRON_LOG=$2; shift 2 ;;
    --cron-bin-dir) CRON_BIN_DIR=$2; shift 2 ;;
    --rotate-cmd) ROTATE_CMD=$2; shift 2 ;;
    -n | --attempts) ATTEMPTS=$2; shift 2 ;;
    --pass-line) PASS_LINE=$2; shift 2 ;;
    --hard-line) HARD_LINE=$2; shift 2 ;;
    --check-ip) CHECK_IP=$2; shift 2 ;;
    --deep) DEEP=1; shift ;;
    --no-proxycheck) NO_PROXYCHECK=1; shift ;;
    --no-direct) NO_DIRECT=1; shift ;;
    --wait-change) WAIT_CHANGE=$2; shift 2 ;;
    --log) LOG_FILE=$2; shift 2 ;;
    --cache) CACHE_FILE=$2; shift 2 ;;
    --cache-ttl) CACHE_TTL=$2; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --fresh) JINA_FRESH=1; shift ;;
    --no-jina-cache) JINA_FRESH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
        echo "未知参数：$1（--help 看用法）" >&2
        exit 2
        ;;
    esac
done

# 缓存文件：显式指定 > $HOME 可写 > /tmp
[ -n "$CACHE_FILE" ] || CACHE_FILE="$(writable_home)/.ip_rotate_cache.tsv"
case "$CACHE_TTL" in '' | *[!0-9]*) CACHE_TTL=21600 ;; esac

# 无参数且在终端里跑（比如从 tmd 菜单拉起）：问要用的换 IP 接法和阈值
interactive_setup() {
    echo "=== IP 质量体检（回车沿用默认值） ==="
    if [ -n "$ROTATE_URL" ]; then
        _def=1
    elif [ -n "$ROTATE_CMD" ]; then
        _def=2
    else
        _def=3
    fi
    echo "换 IP 方式：1) HTTP 接口  2) 自定义命令  3) 只体检不换"
    printf "选择 [%s]：" "$_def"
    read _in
    [ -n "$_in" ] && _def=$_in
    case "$_def" in
    1)
        printf "换 IP 接口 URL [%s]：" "$ROTATE_URL"
        read _in
        [ -n "$_in" ] && ROTATE_URL=$_in
        ROTATE_CMD=""
        printf "请求方法 GET/POST [%s]：" "$ROTATE_METHOD"
        read _in
        [ -n "$_in" ] && ROTATE_METHOD=$_in
        printf "POST body（GET 就留空）[%s]：" "$ROTATE_DATA"
        read _in
        [ -n "$_in" ] && ROTATE_DATA=$_in
        printf "接口鉴权放 Authorization 头[%s]：" "${ROTATE_TOKEN:+已设置，回车沿用}"
        read _in
        [ -n "$_in" ] && ROTATE_TOKEN=$_in
        ;;
    2)
        printf "换 IP 命令 [%s]：" "$ROTATE_CMD"
        read _in
        [ -n "$_in" ] && ROTATE_CMD=$_in
        ROTATE_URL=""
        ;;
    *)
        ROTATE_URL=""
        ROTATE_CMD=""
        ;;
    esac
    printf "最多尝试 %s 次，回车确认或输入新值：" "$ATTEMPTS"
    read _in
    [ -n "$_in" ] && ATTEMPTS=$_in
    _d=N
    [ "$DEEP" = 1 ] && _d=Y
    printf "总是查 proxycheck（多耗额度）？[%s]：" "$_d"
    read _in
    case "$_in" in
    y | Y) DEEP=1 ;;
    n | N) DEEP=0 ;;
    esac
    if have_rotate; then
        [ -n "$CONF_FILE" ] || CONF_FILE="$(writable_home)/.ip_rotate.conf"
        printf "保存到 %s 下次直接复用？[Y/n]：" "$CONF_FILE"
        read _in
        case "$_in" in
        n | N) : ;;
        *) save_conf "$CONF_FILE" && echo "已保存：$CONF_FILE（下次回车即可沿用）" ;;
        esac
    fi
    if have crontab; then
        printf "装到 crontab 每天北京时间 %s 自动跑？[y/N]：" "$CRON_TIME"
        read _in
        case "$_in" in
        y | Y) CRON_MODE=install ;;
        esac
    fi
    echo ""
}

if [ "$_noargs" = 1 ] && [ -t 0 ]; then
    interactive_setup
fi

# --save-conf：把当前设置落地成配置文件后退出（便于脚本化）
if [ "$SAVE_CONF" = 1 ]; then
    [ -n "$CONF_FILE" ] || CONF_FILE="$(writable_home)/.ip_rotate.conf"
    if save_conf "$CONF_FILE"; then
        echo "已保存：$CONF_FILE"
        exit 0
    fi
    echo "保存失败：$CONF_FILE" >&2
    exit 2
fi

# --cron-install / --cron-remove / --cron-print
if [ -n "$CRON_MODE" ]; then
    [ -n "$CONF_FILE" ] || CONF_FILE="$(writable_home)/.ip_rotate.conf"
    case "$CRON_MODE" in
    print)
        echo "# 本机 crontab 将新增这一行（北京时间 ${CRON_TIME} = 本机时间 $(bj_to_local_hm "$CRON_TIME")）"
        cron_line
        exit 0
        ;;
    remove)
        cron_remove
        exit $?
        ;;
    install)
        if ! have crontab; then
            echo "系统里没有 crontab，装不了定时任务（OpenWrt 需 opkg install cron）" >&2
            exit 2
        fi
        save_conf "$CONF_FILE" && echo "已保存配置：$CONF_FILE"
        cron_install
        exit $?
        ;;
    esac
fi

# ------------------------- 主流程 -------------------------
print_head

if [ -n "$CHECK_IP" ]; then
    _self=0
    _selfip=$(current_ip) && [ "$_selfip" = "$CHECK_IP" ] && _self=1
    check_one "$CHECK_IP" "$_self" ""
    case "$VERDICT" in
    PASS) exit 0 ;;
    UNKNOWN) exit 2 ;;
    *) exit 1 ;;
    esac
fi

_best_ip=""
_best_score="-1"
_attempt=1
while [ "$_attempt" -le "$ATTEMPTS" ]; do
    ip=$(current_ip)
    if [ -z "$ip" ]; then
        echo "拿不到出口 IP" >&2
        exit 2
    fi

    check_one "$ip" 1 "[$_attempt/$ATTEMPTS] "

    _cur=${SCORE:--1}
    if [ "$_cur" -gt "$_best_score" ]; then
        _best_score=$_cur
        _best_ip=$ip
    fi

    if [ "$VERDICT" = "PASS" ]; then
        echo "=> 可用，停止轮换"
        exit 0
    fi

    [ "$_attempt" -ge "$ATTEMPTS" ] && break
    if ! have_rotate; then
        break
    fi
    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$ROTATE_URL" ]; then
            echo "        [dry-run] 将调用接口（$ROTATE_METHOD）：$ROTATE_URL"
        else
            echo "        [dry-run] 将执行：$ROTATE_CMD"
        fi
        break
    fi

    # 记录换之前的出口 IP：接口调用前现取一次，避免体检那十几秒里出口自己漂移
    _pre_ip=$(current_ip)
    [ -n "$_pre_ip" ] || _pre_ip=$ip
    echo "        换前出口 IP：$_pre_ip" >&2

    if ! do_rotate; then
        echo "        接口/命令没成功，下一轮重试" >&2
        log_event "rotate_fail" "\"from\":\"$_pre_ip\","
        _attempt=$((_attempt + 1))
        sleep 3
        continue
    fi

    # 判断"换完了"只看一件事：出口 IP 变了没有（不看接口返回什么）
    _old_ip=$_pre_ip
    _changed=0
    _now=$_old_ip
    _n=0
    _deadline=$(($(date +%s) + WAIT_CHANGE))
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        sleep 3
        _n=$((_n + 1))
        _probe=$(current_ip) || continue
        _now=$_probe
        if [ "$_now" != "$_old_ip" ]; then
            _changed=1
            break
        fi
        # 每 12 秒报一次进度，避免看起来卡住
        if [ $((_n % 4)) = 0 ]; then
            echo "        仍在等新 IP（$((_n * 3))s / ${WAIT_CHANGE}s），当前 $_now" >&2
        fi
    done

    if [ "$_changed" = 1 ]; then
        echo "        出口已变：$_old_ip -> $_now" >&2
        log_event "rotate_ok" "\"from\":\"$_old_ip\",\"to\":\"$_now\","
    else
        echo "        ${WAIT_CHANGE}s 内出口没变（$_now），下一轮再换" >&2
        log_event "rotate_nochange" "\"ip\":\"$_now\","
    fi
    sleep 2

    _attempt=$((_attempt + 1))
done

if [ "$_best_ip" = "" ]; then
    echo "=> 本轮无合格 IP，最好的是 - (- 分)"
else
    echo "=> 本轮无合格 IP，最好的是 $_best_ip ($_best_score 分)"
fi
exit 1
