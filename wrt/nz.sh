#!/bin/sh

# --- 哪吒监控 (Nezha) 探针 OpenWRT 安装脚本 ---
#
# 说明：
#   官方面板给出的一键安装命令依赖 systemd / OpenRC (kardianos/service)，
#   在 OpenWRT 上无法正确注册服务；本脚本改为：
#     1. 自动识别架构 (含 mips/mipsle 大小端判断)
#     2. 从 GitHub 下载 agent 二进制 (支持国内镜像回退)
#     3. 直接生成 config.yml (不依赖 service install)
#     4. 安装 procd 原生 init 脚本，开机自启 + 崩溃自动重启
#
# 对应官方默认安装命令中的参数：
#   NZ_SERVER=nz-cdn.2026178.xyz:443
#   NZ_TLS=true
#   NZ_CLIENT_SECRET=byRKoDjUCXXYD8Cs3gSbXOL6C7iKr3iR
#
# 用法：
#   nezha                进入交互菜单
#   nezha install        安装并启动探针
#   nezha uninstall      卸载探针 (删除服务与文件)
#   nezha start          启动服务
#   nezha stop           停止服务
#   nezha restart        重启服务
#   nezha status         查看运行状态
#   nezha config         查看当前配置
#
# 安装：放到路由器 /usr/bin/nezha，chmod +x，直接运行 nezha

# ===================== 配置区 =====================
# 服务器/TLS/密钥不写默认值，安装时必须交互输入
# (重装时会自动读取已有 config.yml 作为默认，可回车沿用)
# 面板服务器地址 (域名/IP:端口)
NZ_SERVER=""
# 是否启用 TLS (true/false)
NZ_TLS=""
# 客户端密钥 (Agent Secret)
NZ_CLIENT_SECRET=""
# 探针 UUID (留空则自动生成)
NZ_UUID=""

# 是否跳过证书校验 (自签证书时可设为 true)
NZ_INSECURE_TLS="false"
# 是否关闭自动更新 (路由器建议 true，避免自动升级导致异常)
NZ_DISABLE_AUTO_UPDATE="true"
# 是否关闭远程命令执行 (安全考虑可设为 true)
NZ_DISABLE_COMMAND_EXECUTE="false"
# 上报间隔 (1-4)
NZ_REPORT_DELAY="1"

# GitHub 下载镜像 (国内加速，留空则仅走 GitHub 直连)
# 代理格式: 镜像域名 + github 路径 (不含 https://github.com/)
MIRROR="https://gh.2026178.xyz/"

# --------------------- 路径 ---------------------
NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"
AGENT_BIN="${NZ_AGENT_PATH}/nezha-agent"
CONFIG_FILE="${NZ_AGENT_PATH}/config.yml"
INIT_SCRIPT="/etc/init.d/nezha-agent"
TMP_ZIP="/tmp/nezha-agent.zip"
# 上次输入缓存 (安装失败/中止后重装时用于带出默认值，持久化、root 只读)
STATE_FILE="/etc/nezha-agent.last"
# ==================================================

echolog() {
	local d
	d="$(date "+%Y-%m-%d %H:%M:%S")"
	echo "$d: $*" >&2
}

# 检查依赖 (curl unzip)
deps_check() {
	local missing=""
	command -v curl >/dev/null 2>&1 || missing="${missing} curl"
	command -v unzip >/dev/null 2>&1 || missing="${missing} unzip"
	if [ -n "$missing" ]; then
		echolog "缺少依赖:${missing}"
		echolog "请先安装: opkg update && opkg install${missing}"
		return 1
	fi
	return 0
}

# 识别系统与架构 -> 设置全局 os / os_arch
env_check() {
	local mach
	mach=$(uname -m)
	case "$mach" in
		amd64|x86_64)        os_arch="amd64" ;;
		i386|i686)           os_arch="386" ;;
		aarch64|arm64)       os_arch="arm64" ;;
		*arm*)               os_arch="arm" ;;
		s390x)               os_arch="s390x" ;;
		riscv64)             os_arch="riscv64" ;;
		loongarch64)         os_arch="loong64" ;;
		mips64el|mips64le)   os_arch="mipsle" ;;
		mips64)              os_arch="mips" ;;
		mipsel|mipsle)       os_arch="mipsle" ;;
		mips)                os_arch="mips" ;;
		*)
			echolog "未知架构: $mach"
			return 1
			;;
	esac

	# mips 大小端判断: uname 常把 mipsel 也报成 mips
	# 读取 ELF 头第 6 字节 (EI_DATA): 1=小端(mipsle) 2=大端(mips)
	if [ "$os_arch" = "mips" ]; then
		local ei_data
		ei_data=$(od -An -j5 -N1 -tu1 /bin/busybox 2>/dev/null | tr -d ' ')
		if [ "$ei_data" = "1" ]; then
			os_arch="mipsle"
			echolog "检测到小端 mips，使用 mipsle 版本"
		fi
	fi

	os="linux"
	echolog "系统架构: ${os}_${os_arch}"
	return 0
}

# 下载单个文件并显示定长彩色进度条
# $1=url  $2=输出文件；返回 curl 退出码
fetch_file() {
	local url="$1" out="$2"
	local width=24 total cur pct filled i bar cpid ret

	# 非交互终端 (如 cron) 直接静默下载
	if [ ! -t 2 ]; then
		curl -L --connect-timeout 15 --max-time 300 -f -s "$url" -o "$out"
		return $?
	fi

	# 预取文件大小 (可能为空/拿不到)
	total=$(curl -sIL --connect-timeout 15 "$url" 2>/dev/null | tr -d '\r' \
		| awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')

	curl -L --connect-timeout 15 --max-time 300 -f -s "$url" -o "$out" &
	cpid=$!

	while kill -0 "$cpid" 2>/dev/null; do
		cur=$(wc -c < "$out" 2>/dev/null); cur=${cur:-0}
		if [ "${total:-0}" -gt 0 ]; then
			pct=$(( cur * 100 / total ))
			filled=$(( cur * width / total ))
			[ "$pct" -gt 100 ] && pct=100
			[ "$filled" -gt "$width" ] && filled=$width
		else
			pct=-1; filled=0
		fi
		bar=""; i=0
		while [ $i -lt $filled ]; do bar="${bar}#"; i=$((i+1)); done
		while [ $i -lt $width ];  do bar="${bar}-"; i=$((i+1)); done
		if [ "$pct" -ge 0 ]; then
			printf "\r  \033[32m[%s]\033[0m \033[33m%3d%%\033[0m " "$bar" "$pct" >&2
		else
			printf "\r  \033[36m已下载 %s KB\033[0m " "$(( cur / 1024 ))" >&2
		fi
		sleep 1
	done
	wait "$cpid"; ret=$?

	# 收尾: 成功则显示满格绿条
	if [ "$ret" -eq 0 ] && [ "${total:-0}" -gt 0 ]; then
		bar=""; i=0
		while [ $i -lt $width ]; do bar="${bar}#"; i=$((i+1)); done
		printf "\r  \033[32m[%s]\033[0m \033[33m100%%\033[0m\n" "$bar" >&2
	else
		printf "\n" >&2
	fi
	return $ret
}

# 下载 agent 压缩包 (先镜像后直连)
download_agent() {
	local asset="nezha-agent_${os}_${os_arch}.zip"
	local gh_path="nezhahq/agent/releases/latest/download/${asset}"
	local direct="https://github.com/${gh_path}"
	local urls=""
	[ -n "$MIRROR" ] && urls="${MIRROR}${gh_path}"
	urls="${urls} ${direct}"

	rm -f "$TMP_ZIP"
	local u
	for u in $urls; do
		echolog "下载: $u"
		# 定长彩色进度条 (输出到 stderr)
		if fetch_file "$u" "$TMP_ZIP"; then
			# 校验是否为完整 zip (镜像失效时可能返回 HTML 错误页)
			if [ -s "$TMP_ZIP" ] && unzip -t "$TMP_ZIP" >/dev/null 2>&1; then
				echolog "下载完成并校验通过: $(wc -c < "$TMP_ZIP") 字节"
				return 0
			fi
			echolog "下载内容非有效压缩包 (可能是错误页)，尝试下一个..."
		else
			echolog "该地址下载失败，尝试下一个..."
		fi
		rm -f "$TMP_ZIP"
	done
	echolog "错误: agent 下载失败，请检查网络"
	return 1
}

# 生成配置文件 (保留已有 UUID 以维持面板身份不变)
generate_config() {
	local uuid=""
	# 优先使用用户手动指定的 UUID
	if [ -n "$NZ_UUID" ]; then
		uuid="$NZ_UUID"
		echolog "使用指定探针 UUID: $uuid"
	elif [ -f "$CONFIG_FILE" ]; then
		uuid=$(grep '^uuid:' "$CONFIG_FILE" 2>/dev/null | sed 's/^uuid:[[:space:]]*//' | tr -d '\r"' | head -n 1)
	fi
	if [ -z "$uuid" ]; then
		if [ -r /proc/sys/kernel/random/uuid ]; then
			uuid=$(cat /proc/sys/kernel/random/uuid)
		else
			uuid=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' | \
				sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
		fi
		echolog "生成新的探针 UUID: $uuid"
	else
		echolog "复用已有探针 UUID: $uuid"
	fi

	mkdir -p "$NZ_AGENT_PATH"
	cat > "$CONFIG_FILE" <<EOF
client_secret: ${NZ_CLIENT_SECRET}
debug: false
disable_auto_update: ${NZ_DISABLE_AUTO_UPDATE}
disable_command_execute: ${NZ_DISABLE_COMMAND_EXECUTE}
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: ${NZ_INSECURE_TLS}
ip_report_period: 1800
report_delay: ${NZ_REPORT_DELAY}
server: ${NZ_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${NZ_TLS}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${uuid}
EOF
	chmod 600 "$CONFIG_FILE"
	echolog "配置已写入: $CONFIG_FILE"
}

# 生成 procd init 服务脚本
generate_init() {
	cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common
# 哪吒监控探针 procd 服务

USE_PROCD=1
START=99
STOP=10

AGENT_BIN="${AGENT_BIN}"
CONFIG_FILE="${CONFIG_FILE}"

start_service() {
	[ -x "\$AGENT_BIN" ] || return 1
	procd_open_instance
	procd_set_param command "\$AGENT_BIN" -c "\$CONFIG_FILE"
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

stop_service() {
	:
}
EOF
	chmod +x "$INIT_SCRIPT"
	echolog "已生成服务脚本: $INIT_SCRIPT"
}

# 从已有配置读取字段值 (供交互默认值使用)
# $1 = 字段名 (server/tls/client_secret)
read_cfg_value() {
	[ -f "$CONFIG_FILE" ] || return 1
	grep "^$1:" "$CONFIG_FILE" 2>/dev/null | sed "s/^$1:[[:space:]]*//" | tr -d '\r"' | head -n 1
}

# 从上次输入缓存读取字段值
# $1 = key (NZ_SERVER/NZ_TLS/NZ_CLIENT_SECRET)
read_state_value() {
	[ -f "$STATE_FILE" ] || return 1
	grep "^$1=" "$STATE_FILE" 2>/dev/null | sed "s/^$1=//" | head -n 1
}

# 持久化本次输入 (便于失败重装时带出)
save_input() {
	{
		echo "NZ_SERVER=${NZ_SERVER}"
		echo "NZ_TLS=${NZ_TLS}"
		echo "NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET}"
		echo "NZ_UUID=${NZ_UUID}"
	} > "$STATE_FILE" 2>/dev/null
	chmod 600 "$STATE_FILE" 2>/dev/null
}

# 交互录入面板参数 (回车沿用中括号内默认/已有值)
# 提示走 stderr，避免被重定向捕获
prompt_config() {
	local _in
	# 默认值优先级: 已有 config.yml > 上次输入缓存 > 空
	NZ_SERVER=$(read_cfg_value server);               [ -z "$NZ_SERVER" ]        && NZ_SERVER=$(read_state_value NZ_SERVER)
	NZ_TLS=$(read_cfg_value tls);                     [ -z "$NZ_TLS" ]           && NZ_TLS=$(read_state_value NZ_TLS)
	NZ_CLIENT_SECRET=$(read_cfg_value client_secret); [ -z "$NZ_CLIENT_SECRET" ] && NZ_CLIENT_SECRET=$(read_state_value NZ_CLIENT_SECRET)
	NZ_UUID=$(read_cfg_value uuid);                   [ -z "$NZ_UUID" ]           && NZ_UUID=$(read_state_value NZ_UUID)
	# TLS 为空时给个合理缺省 (仅用于提示默认)
	[ -z "$NZ_TLS" ] && NZ_TLS="true"

	echo "" >&2
	echo "请输入面板参数 (服务器/密钥必填):" >&2

	while :; do
		printf "  服务器地址 (域名/IP:端口)%s: " "$([ -n "$NZ_SERVER" ] && echo " [$NZ_SERVER]")" >&2
		read -r _in
		[ -n "$_in" ] && NZ_SERVER="$_in"
		[ -n "$NZ_SERVER" ] && break
		echo "  服务器地址不能为空" >&2
	done

	while :; do
		printf "  启用 TLS? (true/false) [%s]: " "$NZ_TLS" >&2
		read -r _in
		case "$_in" in
			"")          break ;;
			true|false) NZ_TLS="$_in"; break ;;
			*)          echo "  只能输入 true 或 false" >&2 ;;
		esac
	done

	while :; do
		printf "  客户端密钥 (Client Secret)%s: " "$([ -n "$NZ_CLIENT_SECRET" ] && echo " [$NZ_CLIENT_SECRET]")" >&2
		read -r _in
		[ -n "$_in" ] && NZ_CLIENT_SECRET="$_in"
		[ -n "$NZ_CLIENT_SECRET" ] && break
		echo "  客户端密钥不能为空" >&2
	done

	printf "  探针 UUID (留空自动生成)%s: " "$([ -n "$NZ_UUID" ] && echo " [$NZ_UUID]")" >&2
	read -r _in
	[ -n "$_in" ] && NZ_UUID="$_in"

	echo "" >&2
	echo "  已确认: server=${NZ_SERVER}  tls=${NZ_TLS}  secret=${NZ_CLIENT_SECRET}  uuid=${NZ_UUID:-<自动生成>}" >&2
	echo "" >&2

	# 立即缓存本次输入，即使后续下载/安装失败，下次也能带出
	save_input
}

# 安装流程
do_install() {
	echolog "====== 安装哪吒探针 ======"
	deps_check || return 1
	env_check || return 1

	# 交互录入服务器/TLS/密钥
	prompt_config

	# 清理官方 service install 留下的带后缀残留服务 (避免开机重复启动)
	clean_legacy

	if [ -z "$NZ_SERVER" ]; then
		echolog "错误: NZ_SERVER 不能为空"
		return 1
	fi
	if [ -z "$NZ_CLIENT_SECRET" ]; then
		echolog "错误: NZ_CLIENT_SECRET 不能为空"
		return 1
	fi

	download_agent || return 1

	mkdir -p "$NZ_AGENT_PATH"
	if ! unzip -qo "$TMP_ZIP" -d "$NZ_AGENT_PATH"; then
		echolog "错误: 解压失败"
		rm -f "$TMP_ZIP"
		return 1
	fi
	rm -f "$TMP_ZIP"
	chmod +x "$AGENT_BIN" 2>/dev/null

	if [ ! -x "$AGENT_BIN" ]; then
		echolog "错误: 未找到 agent 二进制 $AGENT_BIN"
		return 1
	fi

	generate_config
	generate_init

	"$INIT_SCRIPT" enable 2>/dev/null
	"$INIT_SCRIPT" restart 2>/dev/null

	sleep 2
	# 安装成功，config.yml 已为权威来源，清掉输入缓存 (避免明文密钥残留)
	rm -f "$STATE_FILE"
	echolog "====== 安装完成 ======"
	do_status
}

# 清理官方 nezha-agent service install 留下的带随机后缀残留服务与配置
# (它们会在 /etc/init.d/nezha-agent-xxxx 与 /etc/rc.d/S50... 重复拉起探针)
clean_legacy() {
	local f found=0
	for f in /etc/init.d/nezha-agent-*; do
		[ -f "$f" ] || continue
		"$f" stop 2>/dev/null
		"$f" disable 2>/dev/null
		rm -f "$f"
		found=1
		echolog "已清理残留服务: $(basename "$f")"
	done
	rm -f /etc/rc.d/*nezha-agent-*
	rm -f "$NZ_AGENT_PATH"/config-*.yml
	return 0
}

# 卸载流程
do_uninstall() {
	echolog "====== 卸载哪吒探针 ======"
	# 主服务 + 所有带后缀的残留服务一并清理
	for f in "$INIT_SCRIPT" /etc/init.d/nezha-agent-*; do
		[ -f "$f" ] || continue
		"$f" stop 2>/dev/null
		"$f" disable 2>/dev/null
		rm -f "$f"
		echolog "已移除服务: $(basename "$f")"
	done
	# 清理残留 rc.d 软链
	rm -f /etc/rc.d/*nezha-agent /etc/rc.d/*nezha-agent-*
	killall nezha-agent 2>/dev/null
	rm -rf "$NZ_BASE_PATH"
	rm -f "$STATE_FILE"
	echolog "已删除 $NZ_BASE_PATH"
	echolog "====== 卸载完成 ======"
}

do_start() {
	[ -f "$INIT_SCRIPT" ] || { echolog "未安装，请先运行 nezha install"; return 1; }
	"$INIT_SCRIPT" start && echolog "已启动"
}

do_stop() {
	[ -f "$INIT_SCRIPT" ] || { echolog "未安装"; return 1; }
	"$INIT_SCRIPT" stop && echolog "已停止"
}

do_restart() {
	[ -f "$INIT_SCRIPT" ] || { echolog "未安装，请先运行 nezha install"; return 1; }
	"$INIT_SCRIPT" restart && echolog "已重启"
}

# 查看状态
do_status() {
	echo "===== 哪吒探针状态 ====="
	echo "服务器地址  : ${NZ_SERVER}"
	echo "TLS         : ${NZ_TLS}"
	echo "二进制      : ${AGENT_BIN} ($([ -x "$AGENT_BIN" ] && echo '存在' || echo '缺失'))"
	echo "配置文件    : ${CONFIG_FILE} ($([ -f "$CONFIG_FILE" ] && echo '存在' || echo '缺失'))"
	if [ -f "$CONFIG_FILE" ]; then
		echo "探针 UUID   : $(grep '^uuid:' "$CONFIG_FILE" | sed 's/^uuid:[[:space:]]*//')"
	fi
	if [ -f "$INIT_SCRIPT" ]; then
		echo "开机自启    : $("$INIT_SCRIPT" enabled 2>/dev/null && echo '已启用' || echo '未启用')"
	else
		echo "开机自启    : 未安装"
	fi
	local pid
	pid=$(pgrep -f "nezha-agent -c" 2>/dev/null | head -n 1)
	if [ -n "$pid" ]; then
		echo "运行状态    : 运行中 (PID $pid)"
	else
		echo "运行状态    : 未运行"
	fi
	echo "======================="
}

# 查看配置
do_config() {
	if [ -f "$CONFIG_FILE" ]; then
		echo "配置文件: $CONFIG_FILE"
		echo "-----------------------------------"
		cat "$CONFIG_FILE"
	else
		echo "配置文件不存在，请先运行 nezha install"
	fi
}

# ===================== 交互菜单 =====================
run_menu() {
	while :; do
		clear 2>/dev/null || true
		local run_status="未运行"
		pgrep -f "nezha-agent -c" >/dev/null 2>&1 && run_status="运行中"
		local inst_status="未安装"
		[ -x "$AGENT_BIN" ] && inst_status="已安装"
		echo ""
		echo "=========================================="
		echo "    哪吒监控探针 (OpenWRT)"
		echo "=========================================="
		echo "  状态: ${inst_status}        运行: ${run_status}"
		echo "  服务器: ${NZ_SERVER}"
		echo "------------------------------------------"
		echo "  1) install    安装并启动探针"
		echo "  2) status     查看运行状态"
		echo "  3) restart    重启服务"
		echo "  4) stop       停止服务"
		echo "  5) start      启动服务"
		echo "  6) config     查看当前配置"
		echo "  7) uninstall  卸载探针"
		echo "------------------------------------------"
		echo "  0) 退出"
		echo "=========================================="
		printf "请选择 [0-7]: "
		read -r choice
		echo ""
		case "$choice" in
			1|install)   do_install ;;
			2|status)    do_status ;;
			3|restart)   do_restart ;;
			4|stop)      do_stop ;;
			5|start)     do_start ;;
			6|config)    do_config ;;
			7|uninstall)
				printf "确认卸载? (y/n): "
				read -r yn
				[ "$yn" = "y" ] || [ "$yn" = "Y" ] && do_uninstall
				;;
			0|exit|q)    exit 0 ;;
			*)
				echo "无效选择，请输入 0-7"
				sleep 1
				continue
				;;
		esac
		echo ""
		printf "按回车键返回菜单..."
		read -r
	done
}

# ===================== 入口 =====================
case "${1:-}" in
	install)    do_install ;;
	uninstall)  do_uninstall ;;
	start)      do_start ;;
	stop)       do_stop ;;
	restart)    do_restart ;;
	status)     do_status ;;
	config)     do_config ;;
	"")         run_menu ;;
	*)
		echo "未知命令: $1"
		echo "用法: $0 {install|uninstall|start|stop|restart|status|config}"
		exit 1
		;;
esac
