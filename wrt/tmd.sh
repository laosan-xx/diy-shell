#!/bin/sh
# tmd - 在线脚本
# 运行脚本列表与脚本按需从 GitHub 拉取，本体更新改为手动。
# 适用于 OpenWRT（busybox ash）。
#
# 安装：由 OpenWRT-CI 编译流程从目标仓库下载并装入 /usr/bin/tmd。
# 更新策略（方案 1 + 方案 4）：
#   - 启动时完全不联网检查本体，直接进入脚本菜单。
#   - `tmd check`  轻量比对：仅拉取 API 中的 sha，与本地记录比对，不下本体。
#   - `tmd update` 真正下载并覆盖本体，并写回新的 sha。
# 本地 sha 记录存于 SELF_SHA 文件，由 update 建立/刷新。

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

# 获取远程 tmd.sh 的 Git blob sha（来自 Contents API，仅几百字节）
get_remote_self_sha() {
    $FETCH "${API_URL}" 2>/dev/null \
        | grep -o '"name": *"tmd\.sh"[^}]*' \
        | grep -o '"sha": *"[^"]*"' \
        | head -n1 | sed 's/"sha": *"//; s/"$//'
}

# 从单文件 Contents API 直接拿到某文件的 sha（通用）
# $1 = 文件名；请求 .../contents/wrt/<文件名>?ref=<分支>
get_file_sha() {
    local url="${FILE_API_URL}/$1?ref=${REPO_BRANCH}"
    $FETCH "$url" 2>/dev/null \
        | grep -o '"sha": *"[^"]*"' \
        | head -n1 | sed 's/"sha": *"//; s/"$//'
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

# 子命令处理：仅当作为已安装本体运行时，支持 check / update
if [ "$0" = "$SELF" ]; then
    case "$1" in
        check)  do_check;  exit $? ;;
        update) do_update; exit $? ;;
    esac
fi

echo "正在从 GitHub 获取脚本列表 ..."
JSON=$($FETCH "$API_URL" 2>/dev/null)
if [ -z "$JSON" ]; then
    echo "错误：无法获取脚本列表（网络问题或 GitHub API 限流）。" >&2
    exit 1
fi

# 提取目录下所有 .sh 文件名（保持 JSON 中的顺序），排除自身
NAMES=$(echo "$JSON" | grep -o '"name": *"[^"]*\.sh"' | sed 's/"name": *"//; s/"$//' | grep -v '^tmd\.sh$')
if [ -z "$NAMES" ]; then
    echo "错误：未在 ${REPO_DIR}/ 下找到任何 .sh 脚本。" >&2
    exit 1
fi

echo ""
echo "=== TMD 常用脚本 ==="
i=1
for n in $NAMES; do
    printf "  %2d) %s\n" "$i" "$n"
    i=$((i+1))
done
echo "   q) 退出"
echo ""
printf "请选择要运行的脚本编号: "
read choice

case "$choice" in
    q|Q) echo "已取消。"; exit 0 ;;
    '' ) echo "未选择，退出。"; exit 0 ;;
esac

# 根据编号取出对应文件名
sel=$(echo "$NAMES" | sed -n "${choice}p")
if [ -z "$sel" ]; then
    echo "无效编号: $choice" >&2
    exit 1
fi

SCRIPT_URL="${RAW_BASE}/${sel}"
TMP="/tmp/tmd_${sel}.$$"

echo "正在下载脚本: $sel"
$FETCH "$SCRIPT_URL" > "$TMP" 2>/dev/null
if [ ! -s "$TMP" ]; then
    echo "错误：下载脚本失败: $SCRIPT_URL" >&2
    rm -f "$TMP"
    exit 1
fi

echo "----------------------------------------"
echo "运行: $sel (从 $SCRIPT_URL)"
echo "----------------------------------------"
sh "$TMP"
rc=$?
rm -f "$TMP"
exit $rc
