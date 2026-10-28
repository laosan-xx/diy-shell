#!/bin/sh
# desc: TMD 脚本菜单（列表 + 本地缓存）
# tmd - 在线脚本（带本地缓存，避免每次联网）
# 适用于 OpenWRT（busybox ash）。
#
# 安装：由 OpenWRT-CI 编译流程从目标仓库下载并装入 /usr/bin/tmd。
# 缓存策略：
#   - 脚本列表（目录 Contents API）缓存到本地，默认 10 分钟内复用，不重复联网。
#   - 选中的脚本也缓存到本地，已缓存则直接运行，缺失才下载。
#   - `tmd refresh` 强制刷新列表缓存；`tmd run <名>` 直接运行（离线优先）。
# 本体更新策略：
#   - `tmd check`  轻量比对：仅拉取 API 中的 sha，与本地记录比对，不下本体。
#   - `tmd update` 真正下载并覆盖本体，并写回新的 sha。
# 本地 sha 记录存于 SELF_SHA 文件，由 update 建立/刷新。
# 菜单显示：
#   - 列表里显示"中文名（真实文件名）"。中文名优先取脚本自身头部的
#     "# desc: xxx" 注释（前 4KB 内），刷新列表时抓取并缓存到本地索引，
#     所以新增脚本只要在头部写一行 desc，不用再回来改 tmd.sh。
#   - 抓取遵守"sha 没变就复用旧描述"，日常 refresh 不会重复下载。
#   - 抓不到（网络失败 / 脚本没写 desc）时菜单退回显示裸文件名，不影响运行。
#   - `tmd run <名>`、编号选择仍以真实文件名为准。

REPO_OWNER="laosan-xx"
REPO_NAME="diy-shell"
REPO_BRANCH="main"
REPO_DIR="wrt"
PROXY="https://gh.2026178.xyz"
API_URL="${PROXY}/api/repos/${REPO_OWNER}/${REPO_NAME}/contents/${REPO_DIR}?ref=${REPO_BRANCH}"
# 单文件 Contents API：直接拿到某个文件条目的 sha，比拉整个目录更精准、更省流量
FILE_API_URL="${PROXY}/api/repos/${REPO_OWNER}/${REPO_NAME}/contents/${REPO_DIR}"
RAW_BASE="${PROXY}/raw/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/${REPO_DIR}"

# 自身在系统中的安装路径，以及目标仓库中的本体地址（用于自更新）
SELF="/usr/bin/tmd"
SELF_REMOTE="${RAW_BASE}/tmd.sh"
# 记录已安装本体 sha 的文件（与 SELF 同目录）
SELF_SHA="${SELF}.sha"

# 本地缓存（tmpfs，重启即清；同一运行期内复用可显著提速）
CACHE_DIR="/tmp/tmd.d"
INDEX="${CACHE_DIR}/index"
SCRIPTS="${CACHE_DIR}/scripts"
DESC_TMP="${CACHE_DIR}/desc"   # 本次刷新抓到的自描述暂存目录
TAB=$(printf '\t')             # 索引是 name<TAB>sha<TAB>desc 三列
CACHE_TTL=600   # 列表缓存有效期（秒），默认 10 分钟

# 选择可用的下载器
if command -v uclient-fetch >/dev/null 2>&1; then
    FETCH="uclient-fetch -q -O -"
elif command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -q -O -"
else
    echo "错误：未找到 uclient-fetch / curl / wget，无法下载。" >&2
    exit 1
fi

# 从单文件 Contents API 直接拿到某文件的 sha（通用）
# $1 = 文件名；请求 .../contents/wrt/<文件名>?ref=<分支>
get_file_sha() {
    local url="${FILE_API_URL}/$1?ref=${REPO_BRANCH}"
    $FETCH "$url" 2>/dev/null \
        | grep -o '"sha": *"[^"]*"' \
        | head -n1 | sed 's/"sha": *"//; s/"$//'
}

# ---------- 本地缓存：列表 + 脚本 ----------
# 解析目录 Contents API 的 JSON，逐行输出 "name<TAB>sha"（排除 tmd.sh）
parse_index() {
    grep -o '"name": *"[^"]*\.sh"[^}]*' \
    | while IFS= read -r obj; do
        name=$(echo "$obj" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p')
        sha=$(echo "$obj" | sed -n 's/.*"sha": *"\([^"]*\)".*/\1/p')
        [ "$name" = "tmd.sh" ] && continue
        [ -n "$name" ] && printf '%s\t%s\n' "$name" "$sha"
    done
}

# 读取单个脚本的自描述：约定在脚本头部 4KB 内写一行
#   # desc: 中文说明
# 抓不到就留空，由 desc_of() 的内置表兜底
fetch_desc() {
    mkdir -p "$DESC_TMP"
    raw="${DESC_TMP}/.raw.$1"
    $FETCH "${RAW_BASE}/$1" 2>/dev/null | head -c 4096 2>/dev/null > "$raw"
    if [ ! -s "$raw" ]; then
        rm -f "$raw"
        return 1 # 下载失败：不落结果，留待下次刷新重试
    fi
    sed -n 's/^#[[:space:]]*desc:[[:space:]]*//p' "$raw" | head -n1 > "${DESC_TMP}/$1"
    rm -f "$raw"
}

# 拉取并刷新脚本列表缓存；成功返回 0
# 索引格式：#ts <时间戳> + 每行 name<TAB>sha<TAB>desc
fetch_index() {
    local json name sha desc todo i cnt
    json=$($FETCH "$API_URL" 2>/dev/null)
    if [ -z "$json" ]; then
        return 1
    fi
    mkdir -p "$CACHE_DIR" "$SCRIPTS"
    echo "$json" | parse_index > "${CACHE_DIR}/index.new" || return 1

    # 脚本 sha 没变就沿用旧缓存里的中文名，日常刷新不会再逐个下载
    # （即使旧描述是空的也沿用：说明已抓过、脚本本身没写 desc，不必重抓）
    [ -f "$INDEX" ] || echo "#ts 0" > "$INDEX"
    # 旧版本缓存只有两列（没有 desc），这种条目当作"未抓过"重抓一次
    awk -F'\t' '
        NR == FNR {
            if ($1 ~ /^#/ || NF < 2) next
            s[$1] = $2
            d[$1] = (NF >= 3 ? $3 : "__FETCH__")
            next
        }
        { printf "%s\t%s\t%s\n", $1, $2, (s[$1] == $2 ? d[$1] : "__FETCH__") }
    ' "$INDEX" "${CACHE_DIR}/index.new" > "${CACHE_DIR}/index.merged"

    # 只抓新出现 / 内容有变化 / 上次没抓成功的脚本
    todo=$(awk -F'\t' '$3 == "__FETCH__" || $3 == "__RETRY__" { print $1 }' "${CACHE_DIR}/index.merged")
    if [ -n "$todo" ]; then
        rm -rf "$DESC_TMP"
        mkdir -p "$DESC_TMP"
        cnt=$(echo $todo | wc -w | tr -d ' ')
        echo "正在读取脚本自描述（${cnt} 个，仅首次或有更新时才联网）..."
        i=0
        for name in $todo; do
            fetch_desc "$name" &
            i=$((i + 1))
            [ $((i % 4)) -eq 0 ] && wait
        done
        wait
    fi

    {
        echo "#ts $(date +%s)"
        while IFS="$TAB" read -r name sha desc; do
            [ -z "$name" ] && continue
            if [ "$desc" = "__FETCH__" ] || [ "$desc" = "__RETRY__" ]; then
                if [ -f "${DESC_TMP}/$name" ]; then
                    desc=$(cat "${DESC_TMP}/$name" 2>/dev/null)
                else
                    desc="__RETRY__" # 没抓成功，留着下次重试
                fi
            fi
            if [ -n "$desc" ]; then
                printf '%s\t%s\t%s\n' "$name" "$sha" "$desc"
            else
                printf '%s\t%s\t\n' "$name" "$sha"
            fi
        done < "${CACHE_DIR}/index.merged"
    } > "${INDEX}.tmp" && mv -f "${INDEX}.tmp" "$INDEX" || return 1

    rm -f "${CACHE_DIR}/index.new" "${CACHE_DIR}/index.merged"
    # 列表已更新，脚本缓存失效，清除以便按需重新下载
    rm -rf "$SCRIPTS"; mkdir -p "$SCRIPTS"
    return 0
}

# 列表缓存是否有效（存在且未超过 TTL）
cache_valid() {
    [ -f "$INDEX" ] || return 1
    local now ts
    now=$(date +%s)
    ts=$(sed -n 's/^#ts //p' "$INDEX" | head -n1)
    [ -n "$ts" ] || return 1
    [ "$((now - ts))" -lt "$CACHE_TTL" ]
}

# 从缓存读取脚本名列表（每行一个，跳过 # 头）
load_names() {
    sed -e '/^#/d' -e 's/\t.*//' "$INDEX"
}

# 脚本的中文名（菜单里显示中文，括号内保留真实文件名，`tmd run` 仍用文件名）
# 唯一来源是脚本头部的 "# desc:"（刷新列表时抓进索引），抓不到就返回空
desc_of() {
    local d
    d=$(awk -F'\t' -v n="$1" '$1 == n { print $3; exit }' "$INDEX" 2>/dev/null)
    case "$d" in
    __FETCH__ | __RETRY__) d="" ;; # 内部占位符，视为没抓到
    esac
    printf '%s\n' "$d"
}

# 运行指定脚本：优先用本地缓存，缺失才下载
run_named() {
    local name="$1"
    local cached="$SCRIPTS/$name"
    if [ ! -s "$cached" ]; then
        echo "正在下载脚本: $name"
        mkdir -p "$SCRIPTS"
        $FETCH "${RAW_BASE}/${name}" > "$cached" 2>/dev/null
    fi
    if [ ! -s "$cached" ]; then
        echo "错误：脚本不可用（网络问题或文件不存在）: $name" >&2
        rm -f "$cached"
        return 1
    fi
    echo "----------------------------------------"
    echo "运行: $name"
    echo "----------------------------------------"
    sh "$cached"
}

# 检查更新（轻量，不下本体）：比对远程 sha 与本地记录
do_check() {
    echo "正在检查 TMD 更新 ..."
    if [ ! -f "$SELF_SHA" ]; then
        echo "本地版本未登记（缺少 $SELF_SHA）。"
        echo "建议运行: tmd update  以登记当前版本 / 升级到最新版本。"
        return 0
    fi
    local_sha=$(cat "$SELF_SHA" 2>/dev/null)
    remote_sha=$(get_file_sha "tmd.sh")
    if [ -z "$remote_sha" ]; then
        echo "错误：无法获取远程版本信息（网络问题或限流）。" >&2
        return 1
    fi
    if [ "$local_sha" = "$remote_sha" ]; then
        echo "TMD 已是最新版本。"
    else
        echo "检测到 TMD 有新版本可用。"
        echo "  本地: ${local_sha:-未知}"
        echo "  远程: ${remote_sha}"
        echo "运行 'tmd update' 可升级。"
    fi
    return 0
}

# 真正下载并覆盖本体，写回新的 sha
do_update() {
    echo "正在下载最新 TMD 本体 ..."
    TMP_SELF="/tmp/tmd_self.$$"
    if ! $FETCH "$SELF_REMOTE" > "$TMP_SELF" 2>/dev/null || [ ! -s "$TMP_SELF" ]; then
        echo "错误：下载 TMD 本体失败: $SELF_REMOTE" >&2
        rm -f "$TMP_SELF"
        return 1
    fi
    cp -f "$TMP_SELF" "$SELF" && chmod +x "$SELF"
    rm -f "$TMP_SELF"
    # 刷新本地 sha 记录
    new_sha=$(get_file_sha "tmd.sh")
    if [ -n "$new_sha" ]; then
        echo "$new_sha" > "$SELF_SHA"
    fi
    echo "TMD 已更新到最新版本。"
    return 0
}

# 将 host 解析写入 OpenWRT 的 /etc/hosts
# 已存在该 host 的旧条目则删除后重写，否则追加
set_openwrt_host() {
    local host="$1" ip="$2"
    local hosts="/etc/hosts"
    if [ ! -f "$hosts" ]; then
        echo "错误：找不到 $hosts" >&2
        return 1
    fi
    if [ ! -w "$hosts" ]; then
        echo "错误：无权限写入 $hosts（请使用 root 运行）。" >&2
        return 1
    fi
    # 转义 host 中的正则元字符，避免 sed 误匹配
    local esc_host=$(printf '%s' "$host" | sed 's/[][\.*^$/]/\\&/g')
    # 删除所有以该 host 结尾的旧条目
    sed -i "/[[:space:]]${esc_host}\$/d" "$hosts"
    # 追加新条目（IP<TAB>host）
    printf '%s\t%s\n' "$ip" "$host" >> "$hosts"
    echo "已写入 hosts: ${ip} ${host}"
    return 0
}

# 获取并设置 gh.2026178.xyz 的 hosts 解析
# 数据源：https://ip.164746.xyz/ipTop.html
# 返回形如 " 104.16.204.6,104.18.103.125 "，取第一个 IP 写入 /etc/hosts
do_sethost() {
    local host="gh.2026178.xyz"
    local src="https://ip.164746.xyz/ipTop.html"
    echo "正在获取 ${host} 的可用 IP（来源: ${src}）..."
    local raw=$($FETCH "$src" 2>/dev/null)
    if [ -z "$raw" ]; then
        echo "错误：无法获取 IP 列表: $src" >&2
        return 1
    fi
    # 拆分逗号、去空格/制表/回车，提取首个合法 IPv4
    local ip=$(echo "$raw" | tr ',' '\n' | tr -d ' \t\r' \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1)
    if [ -z "$ip" ]; then
        echo "错误：未从返回中解析到有效 IP，原始返回: $raw" >&2
        return 1
    fi
    echo "解析到首个 IP: $ip"
    set_openwrt_host "$host" "$ip"
    return $?
}

# 恢复：从 /etc/hosts 中删除 gh.2026178.xyz 的条目（撤销 sethost 的效果）
do_restorehost() {
    local host="gh.2026178.xyz"
    local hosts="/etc/hosts"
    if [ ! -f "$hosts" ]; then
        echo "错误：找不到 $hosts" >&2
        return 1
    fi
    if [ ! -w "$hosts" ]; then
        echo "错误：无权限写入 $hosts（请使用 root 运行）。" >&2
        return 1
    fi
    local esc_host=$(printf '%s' "$host" | sed 's/[][\.*^$/]/\\&/g')
    local before=$(grep -c "[[:space:]]${esc_host}\$" "$hosts" 2>/dev/null || true)
    sed -i "/[[:space:]]${esc_host}\$/d" "$hosts"
    if [ "$before" -gt 0 ]; then
        echo "已清除 ${host} 的 hosts 条目（共 ${before} 条）。"
    else
        echo "${host} 在 ${hosts} 中不存在条目，无需恢复。"
    fi
    return 0
}

# 子命令处理：仅当作为已安装本体运行时，支持 check / update / sethost / restore / refresh / run
if [ "$0" = "$SELF" ]; then
    case "$1" in
        check)    do_check;    exit $? ;;
        update)   do_update;   exit $? ;;
        sethost)  do_sethost;  exit $? ;;
        restore)  do_restorehost; exit $? ;;
        refresh)  fetch_index && echo "脚本列表已刷新。" || { echo "刷新失败（网络问题）。" >&2; exit 1; } ;;
        run)      shift; if [ -z "$1" ]; then echo "用法: tmd run <脚本名>" >&2; exit 1; fi; run_named "$1"; exit $? ;;
    esac
fi

mkdir -p "$CACHE_DIR" "$SCRIPTS"

# 列表优先用本地缓存；缓存过期或不存在才联网刷新；刷新失败则回退缓存
if cache_valid; then
    :
elif fetch_index; then
    echo "（已刷新脚本列表缓存）"
elif [ -f "$INDEX" ]; then
    echo "警告：刷新脚本列表失败，暂用本地缓存（可能已过期）。" >&2
else
    echo "错误：无法获取脚本列表（网络问题或 GitHub API 限流）。" >&2
    exit 1
fi

NAMES=$(load_names)
if [ -z "$NAMES" ]; then
    echo "错误：未在 ${REPO_DIR}/ 下找到任何 .sh 脚本。" >&2
    exit 1
fi

echo ""
echo "=== TMD 常用脚本 ==="
i=1
for n in $NAMES; do
    desc=$(desc_of "$n")
    if [ -n "$desc" ]; then
        printf "  %2d) %s（%s）\n" "$i" "$desc" "$n"
    else
        printf "  %2d) %s\n" "$i" "$n"
    fi
    i=$((i+1))
done
echo "   h) 设置 gh.2026178.xyz 的 hosts"
echo "   r) 恢复 gh.2026178.xyz（清除 hosts 条目）"
echo "   q) 退出"
echo ""
printf "请选择要运行的脚本编号: "
read choice

case "$choice" in
    q|Q) echo "已取消。"; exit 0 ;;
    h|H) do_sethost; exit $? ;;
    r|R) do_restorehost; exit $? ;;
    '' ) echo "未选择，退出。"; exit 0 ;;
esac

# 根据编号取出对应文件名
sel=$(echo "$NAMES" | sed -n "${choice}p")
if [ -z "$sel" ]; then
    echo "无效编号: $choice" >&2
    exit 1
fi

run_named "$sel"
exit $?
