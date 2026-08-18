#!/bin/sh

# --- Cloudflare CDN IP 优选脚本 ---
# 依赖: cdnspeedtest 二进制 (CONFIG_PACKAGE_cdnspeedtest)
#
# 功能：
#   1. 支持 IPv4 / IPv6 / 双栈测速
#   2. 测速前自动下载最新 IP 列表到 /tmp
#   3. 测试完成后取出平均延迟最低的 N 个 IP
#   4. 交互菜单（直接运行 cf 即可进入）
#
# 用法：
#   cf                  进入交互菜单
#   cf start [m]        完整流程 (检测代理->测速->推送)
#   cf test [m] [CIDR]  快速测速 (留空随机，-allip 测全部 IP，默认推送，no-push 关闭)
#   cf push [m]         仅推送已有结果
#   cf mode [m]         切换/查看测试模式
#   cf result           查看上次结果
#   cf download         手动更新 IP 列表
#   cf status           查看状态
#   cf cron-on [m]      开启定时任务
#   cf cron-off         关闭定时任务
#
#   [m] 可选: ipv4(默认) | ipv6 | both
#
# 安装：放到路由器 /usr/bin/cf，chmod +x，直接运行 cf

# ===================== 配置区 =====================
# 脚本路径 (用于 cron 调用，按实际安装路径修改)
SCRIPT_PATH="/usr/bin/cf"

# 定时任务 (cron-on 使用以下时间)
CRON_HOUR=5             # 小时 (0-23)，默认 5 点
CRON_MINUTE=0           # 分钟 (0-59)，默认 0 分

# 测试模式: ipv4 | ipv6 | both
MODE="ipv4"

# Telegram 推送

TG_BOT_TOKEN="7622740934:AAETTKoZ_E0EYxUbINpEdzMi__i09uqyqsA"         # Telegram Bot Token
TG_CHAT_ID="812793390"           # Telegram Chat ID
TG_API="tg.2026178.xyz"  # API 地址，国内可填反代

# 推送 IP 数量
TOP_N=5

# --------------------- 路径 ---------------------
CFST="cdnspeedtest"
RESULT_FILE="/tmp/cloudflarespeedtestresult.txt"
IPV4_TXT="/tmp/ip.txt"
IPV6_TXT="/tmp/ipv6.txt"
IP_URL_V4="https://gh.2026178.xyz/raw/XIU2/CloudflareSpeedTest/master/ip.txt"
IP_URL_V6="https://gh.2026178.xyz/raw/XIU2/CloudflareSpeedTest/master/ipv6.txt"
CRON_FILE="/etc/crontabs/root"

# --------------------- 测试参数 (正式 start/cron 使用) ---------------------
TEST_URL="https://cloudflaremirrors.com/oracle/OL9/u1/x86_64/OracleLinux-R9-U1-x86_64-dvd.iso"
TEST_THREADS=10         # -n  延迟测速并发线程
TEST_COUNT=10           # -t  每个 IP 测速次数
TEST_PORT=80            # -tp 测速端口
TEST_LATENCY_UPPER=200  # -tl 平均延迟上限
TEST_LATENCY_LOWER=20   # -tll 平均延迟下限
TEST_LOSS_UPPER=0.2     # -tlr 丢包率上限
TEST_DISPLAY=0          # -p  屏幕显示数量 (0=不显示，结果仍写入文件)
DISABLE_DOWNLOAD=1      # -dd 仅延迟测速 (1=启用, 0=关闭)

# 快速测试参数 (cf test 使用): 随机取一个 IP 段 -ip，用 -n 100 -t 4 加速
FAST_THREADS=100        # -n  快速测试并发线程
FAST_COUNT=4            # -t  快速测试次数
FAST_DISPLAY=5          # -p  快速测试屏幕显示数量 (5=显示5条，0=不显示)
# ==================================================

echolog() {
	local d
	d="$(date "+%Y-%m-%d %H:%M:%S")"
	echo -e "$d: $*" >&2
}

# 检查 cdnspeedtest 是否可用
find_cfst() {
	if command -v cdnspeedtest >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# 下载/确保 IP 列表存在
ensure_ip_list() {
	case "$1" in
		v4)
			if [ ! -f "$IPV4_TXT" ] || [ ! -s "$IPV4_TXT" ]; then
				echolog "下载 IPv4 IP 列表..."
				curl -sL --connect-timeout 10 --max-time 30 "$IP_URL_V4" -o "$IPV4_TXT" 2>/dev/null
				if [ -s "$IPV4_TXT" ]; then
					echolog "IPv4 列表下载完成: $(wc -l < "$IPV4_TXT") 行"
				else
					echolog "IPv4 列表下载失败"
				fi
			fi
			;;
		v6)
			if [ ! -f "$IPV6_TXT" ] || [ ! -s "$IPV6_TXT" ]; then
				echolog "下载 IPv6 IP 列表..."
				curl -sL --connect-timeout 10 --max-time 30 "$IP_URL_V6" -o "$IPV6_TXT" 2>/dev/null
				if [ -s "$IPV6_TXT" ]; then
					echolog "IPv6 列表下载完成: $(wc -l < "$IPV6_TXT") 行"
				else
					echolog "IPv6 列表下载失败"
				fi
			fi
			;;
	esac
}

# 测试前: 检测并关闭代理插件，记录到 PROXY_STATE_FILE，设置 PROXY_WAS_ON=1
# 测试后: restore_proxy 恢复被关闭的代理 (恢复后再推送，否则 TG 无法连通)
# cf push: proxy_is_on 仅检测当前是否有代理开启(不关闭)
PROXY_STATE_FILE="/tmp/cfst_proxy_state"

disable_proxy() {
	PROXY_WAS_ON=0
	> "$PROXY_STATE_FILE"
	# PassWall
	if [ -f /etc/config/passwall ] && [ "$(uci get passwall.@global[0].enabled 2>/dev/null)" = "1" ]; then
		uci set passwall.@global[0].enabled="0"
		uci commit passwall
		/etc/init.d/passwall stop 2>/dev/null
		echo "passwall" >> "$PROXY_STATE_FILE"
	fi
	# PassWall2
	if [ -f /etc/config/passwall2 ] && [ "$(uci get passwall2.@global[0].enabled 2>/dev/null)" = "1" ]; then
		uci set passwall2.@global[0].enabled="0"
		uci commit passwall2
		/etc/init.d/passwall2 stop 2>/dev/null
		echo "passwall2" >> "$PROXY_STATE_FILE"
	fi
	# OpenClash
	if [ -f /etc/config/openclash ] && [ "$(uci get openclash.config.enable 2>/dev/null)" = "1" ]; then
		uci set openclash.config.enable="0"
		uci commit openclash
		/etc/init.d/openclash stop 2>/dev/null
		echo "openclash" >> "$PROXY_STATE_FILE"
	fi
	# SSR-Plus
	if [ -f /etc/config/shadowsocksr ] && [ "$(uci get shadowsocksr.@global[0].enabled 2>/dev/null)" = "1" ]; then
		uci set shadowsocksr.@global[0].enabled="0"
		uci commit shadowsocksr
		/etc/init.d/shadowsocksr stop 2>/dev/null
		echo "ssrplus" >> "$PROXY_STATE_FILE"
	fi
	# Nikki
	if [ -f /etc/config/nikki ] && [ "$(uci get nikki.config.enable 2>/dev/null)" = "1" ]; then
		uci set nikki.config.enable="0"
		uci commit nikki
		/etc/init.d/nikki stop 2>/dev/null
		echo "nikki" >> "$PROXY_STATE_FILE"
	fi
	# Momo
	if [ -f /etc/config/momo ] && [ "$(uci get momo.config.enable 2>/dev/null)" = "1" ]; then
		uci set momo.config.enable="0"
		uci commit momo
		/etc/init.d/momo stop 2>/dev/null
		echo "momo" >> "$PROXY_STATE_FILE"
	fi
	# HomeProxy
	if [ -f /etc/config/homeproxy ] && [ "$(uci get homeproxy.@global[0].enabled 2>/dev/null)" = "1" ]; then
		uci set homeproxy.@global[0].enabled="0"
		uci commit homeproxy
		/etc/init.d/homeproxy stop 2>/dev/null
		echo "homeproxy" >> "$PROXY_STATE_FILE"
	fi
	# dae
	if [ -f /etc/config/dae ] && [ "$(uci get dae.config.enabled 2>/dev/null)" = "1" ]; then
		uci set dae.config.enabled="0"
		uci commit dae
		/etc/init.d/dae stop 2>/dev/null
		echo "dae" >> "$PROXY_STATE_FILE"
	fi
	# daed
	if [ -f /etc/config/daed ] && [ "$(uci get daed.config.enabled 2>/dev/null)" = "1" ]; then
		uci set daed.config.enabled="0"
		uci commit daed
		/etc/init.d/daed stop 2>/dev/null
		echo "daed" >> "$PROXY_STATE_FILE"
	fi

	if [ -s "$PROXY_STATE_FILE" ]; then
		PROXY_WAS_ON=1
		sleep 2
	fi
}

# 恢复测试前关闭的代理插件
restore_proxy() {
	if [ ! -f "$PROXY_STATE_FILE" ] || [ ! -s "$PROXY_STATE_FILE" ]; then
		rm -f "$PROXY_STATE_FILE"
		return 1
	fi
	while read -r name; do
		[ -z "$name" ] && continue
		case "$name" in
			passwall)
				uci set passwall.@global[0].enabled="1"
				uci commit passwall
				/etc/init.d/passwall start 2>/dev/null
				;;
			passwall2)
				uci set passwall2.@global[0].enabled="1"
				uci commit passwall2
				/etc/init.d/passwall2 start 2>/dev/null
				;;
			openclash)
				uci set openclash.config.enable="1"
				uci commit openclash
				/etc/init.d/openclash start 2>/dev/null
				;;
			ssrplus)
				uci set shadowsocksr.@global[0].enabled="1"
				uci commit shadowsocksr
				/etc/init.d/shadowsocksr start 2>/dev/null
				;;
			nikki)
				uci set nikki.config.enable="1"
				uci commit nikki
				/etc/init.d/nikki start 2>/dev/null
				;;
			momo)
				uci set momo.config.enable="1"
				uci commit momo
				/etc/init.d/momo start 2>/dev/null
				;;
			homeproxy)
				uci set homeproxy.@global[0].enabled="1"
				uci commit homeproxy
				/etc/init.d/homeproxy start 2>/dev/null
				;;
			dae)
				uci set dae.config.enabled="1"
				uci commit dae
				/etc/init.d/dae start 2>/dev/null
				;;
			daed)
				uci set daed.config.enabled="1"
				uci commit daed
				/etc/init.d/daed start 2>/dev/null
				;;
		esac
	done < "$PROXY_STATE_FILE"
	rm -f "$PROXY_STATE_FILE"
	sleep 2
}

# TG 推送直接发送，不需要检测代理状态

# 运行测速命令：stdout→日志，stderr→终端（进度条 \r 在终端正常覆盖）
# $1 = 测速命令字符串
run_cfst() {
	local cmd="$1"

	# stdout→日志，stderr→终端（进度条 \r 在终端正常更新）
	eval "$cmd"

	# 结果摘要
	if [ -s "$RESULT_FILE" ]; then
		local count
		count=$(awk 'END{print NR-1}' "$RESULT_FILE" 2>/dev/null)
		echolog "测速完成: ${count:-0} 个可用 IP"
	else
		echolog "测速完成: 无可用 IP"
	fi
}

# 构建正式测试命令
# $1 = ip 列表文件
build_command() {
	local ip_file="$1"
	local cmd="${CFST} -o ${RESULT_FILE} -f ${ip_file} -url ${TEST_URL}"
	cmd="${cmd} -n ${TEST_THREADS} -t ${TEST_COUNT} -tp ${TEST_PORT}"
	cmd="${cmd} -tl ${TEST_LATENCY_UPPER} -tll ${TEST_LATENCY_LOWER} -tlr ${TEST_LOSS_UPPER}"
	[ "$DISABLE_DOWNLOAD" = "1" ] && cmd="${cmd} -dd"
	cmd="${cmd} -p ${TEST_DISPLAY}"
	echo "$cmd"
}

# 执行 IPv4 正式测速
run_test_v4() {
	ensure_ip_list v4
	local cmd
	cmd=$(build_command "$IPV4_TXT")
	echolog "IPv4 测速中..."
	run_cfst "$cmd"
}

# 执行 IPv6 正式测速
run_test_v6() {
	ensure_ip_list v6
	local cmd
	cmd=$(build_command "$IPV6_TXT")
	echolog "IPv6 测速中..."
	run_cfst "$cmd"
}

# 从 IP 列表文件随机取一行 CIDR (如 103.22.200.0/22)
# $1 = ip 列表文件
random_cidr() {
	local file="$1"
	if [ ! -f "$file" ] || [ ! -s "$file" ]; then
		return 1
	fi
	# 跳过空行/注释行，只取含 "/" 的 CIDR 行，随机输出一个
	awk 'BEGIN{srand()} $0!="" && $0!~/^#/ && $0~/\// {lines[++c]=$0} END{if(c>0) print lines[int(rand()*c)+1]}' "$file"
}

# 构建快速测试命令: 用 -ip <CIDR> 代替 -f，参数 -n 100 -t 4
# $1 = ip 列表文件
# $2 = (可选) 自定义 CIDR，为空则随机选取
# $3 = (可选) allip 标志，非空时追加 -allip 参数
build_command_fast() {
	local ip_file="$1"
	local custom_cidr="${2:-}"
	local allip="${3:-}"
	local cidr
	if [ -n "$custom_cidr" ]; then
		cidr="$custom_cidr"
		echolog "使用指定 IP 段: ${cidr}"
	else
		cidr=$(random_cidr "$ip_file")
		[ -n "$cidr" ] && echolog "随机选取 IP 段: ${cidr}"
	fi
	local cmd
	# 注意: 本函数 stdout 被 $(...) 捕获，echolog 已内置 >&2，不再污染返回的命令
	if [ -n "$cidr" ]; then
		cmd="${CFST} -o ${RESULT_FILE} -ip ${cidr} -url ${TEST_URL}"
	else
		echolog "无法获取随机 IP 段，回退使用 -f ${ip_file}"
		cmd="${CFST} -o ${RESULT_FILE} -f ${ip_file} -url ${TEST_URL}"
	fi
	cmd="${cmd} -n ${FAST_THREADS} -t ${FAST_COUNT} -tp ${TEST_PORT}"
	cmd="${cmd} -tl ${TEST_LATENCY_UPPER} -tll ${TEST_LATENCY_LOWER} -tlr ${TEST_LOSS_UPPER}"
	[ "$DISABLE_DOWNLOAD" = "1" ] && cmd="${cmd} -dd"
	cmd="${cmd} -p ${FAST_DISPLAY}"
	[ -n "$allip" ] && cmd="${cmd} -allip"
	echo "$cmd"
}

# 快速测速 IPv4
# $1 = (可选) 自定义 CIDR
# $2 = (可选) allip 标志
run_fast_test_v4() {
	local custom_cidr="${1:-}"
	local allip="${2:-}"
	ensure_ip_list v4
	local cmd
	cmd=$(build_command_fast "$IPV4_TXT" "$custom_cidr" "$allip")
	echolog "IPv4 快速测速中..."
	run_cfst "$cmd"
}

# 快速测速 IPv6
# $1 = (可选) 自定义 CIDR
# $2 = (可选) allip 标志 (仅 IPv4 有效，传递无影响)
run_fast_test_v6() {
	local custom_cidr="${1:-}"
	local allip="${2:-}"
	ensure_ip_list v6
	local cmd
	cmd=$(build_command_fast "$IPV6_TXT" "$custom_cidr" "$allip")
	echolog "IPv6 快速测速中..."
	run_cfst "$cmd"
}

# 从结果文件取出平均延迟最低的 N 个 IP
# 结果文件 CSV: IP地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s)
# 输出: 每行 "IP 延迟"
get_top() {
	local n="${1:-5}"
	if [ ! -f "$RESULT_FILE" ] || [ ! -s "$RESULT_FILE" ]; then
		echolog "结果文件不存在或为空"
		return
	fi
	# 跳过表头，取第1列(IP)和第5列(平均延迟)，按延迟升序取前 N
	# 过滤：第5列必须为数字、第1列是标准 IPv4(4段) 或 IPv6(含:)
	awk -F, 'NR>1 && NF>=5 && $5 ~ /^[0-9.]+$/ && ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $1 ~ /^[0-9a-fA-F:]+$/) {print $1, $5}' "$RESULT_FILE" \
		| sort -k2 -n | head -n "$n"
}

# 查询本地网络信息 (curl cip.cc)
# 输出: 如 "重庆-联通" / "四川-移动" (省份-运营商)
get_network_info() {
	local info addr operator
	info=$(curl -s --connect-timeout 8 --max-time 15 cip.cc 2>/dev/null)
	if [ -z "$info" ]; then
		echo "获取失败"
		return
	fi
	# 地址行: 取"中国"后的第一个词 (省/直辖市)，如"中国 重庆 重庆" -> "重庆"
	addr=$(echo "$info" | grep '地址' | sed 's/.*[:：] *//;s/^中国 *//' | awk '{print $1}' | tr -d '\r')
	# 运营商行: 去掉"中国"前缀，如"中国联通" -> "联通"
	operator=$(echo "$info" | grep '运营商' | sed 's/.*[:：] *//;s/^中国//;s/^ *//;s/ *$//' | tr -d '\r')
	# 兜底: 若运营商为空(部分响应可能缺运营商行)，从"数据二/三"行 "|" 后取运营商
	if [ -z "$operator" ]; then
		operator=$(echo "$info" | grep '数据' | sed 's/.*| *//' | tr -d '\r' | head -n 1)
	fi
	[ -z "$addr" ] && addr="未知"
	if [ -n "$operator" ]; then
		echo "${addr}-${operator}"
	else
		echo "$addr"
	fi
}

# 格式化 top 列表: 每行 "IP           (延迟ms)"
format_top() {
	awk '{printf "%-18s (%sms)\n", $1, $2}'
}

# 构建推送消息 (单栈)
# $1=网络信息 $2=标签(IPv4/IPv6) $3=top 列表
build_message() {
	local net_info="$1" label="$2" top="$3"
	local now
	now=$(date '+%Y-%m-%d %H:%M:%S')
	local msg="本地网络：${net_info}
测试时间：${now}

${label} 延迟最低的 ${TOP_N} 个 IP："
	if [ -z "$top" ]; then
		msg="${msg}
（无结果）"
	else
		msg="${msg}
$(echo "$top" | format_top)"
	fi
	printf '%s' "$msg"
}

# 构建推送消息 (双栈)
# $1=网络信息 $2=IPv4 top $3=IPv6 top
build_message_both() {
	local net_info="$1" top4="$2" top6="$3"
	local now
	now=$(date '+%Y-%m-%d %H:%M:%S')
	local msg="本地网络：${net_info}
测试时间：${now}

[IPv4] 延迟最低的 ${TOP_N} 个 IP："
	if [ -z "$top4" ]; then
		msg="${msg}
（无结果）"
	else
		msg="${msg}
$(echo "$top4" | format_top)"
	fi
	msg="${msg}

[IPv6] 延迟最低的 ${TOP_N} 个 IP："
	if [ -z "$top6" ]; then
		msg="${msg}
（无结果）"
	else
		msg="${msg}
$(echo "$top6" | format_top)"
	fi
	printf '%s' "$msg"
}

# Telegram 推送
# $1=消息内容
send_telegram() {
	local message="$1"
	if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
		echolog "Telegram Bot Token 或 Chat ID 为空，跳过推送 (请在脚本配置区填写)"
		return 1
	fi
	curl -s -X POST "https://${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" \
		--data-urlencode "chat_id=${TG_CHAT_ID}" \
		--data-urlencode "text=${message}" \
		> /dev/null 2>&1
	if [ $? -eq 0 ]; then
		echolog "Telegram 通知成功"
	else
		echolog "Telegram 通知失败"
	fi
}

# 完整流程: 关闭代理 -> 测速 -> 取 top -> 恢复代理 -> 推送
run_full() {
	rm -f "$RESULT_FILE"
	echolog "====== Cloudflare 优选 IP 任务开始 ======"

	# 1. 关闭代理(若开启)
	disable_proxy

	# 2. 检查 cfst
	if ! find_cfst; then
		echolog "错误: 未找到 cfst 二进制，请先安装 CloudflareSpeedTest"
		restore_proxy
		return 1
	fi

	# 3. 查询本地网络信息 (代理已关闭，直连查询真实本地网络)
	local net_info
	net_info=$(get_network_info)
	echolog "本地网络: ${net_info}"

	# 4. 测速 + 取 top
	local msg=""
	case "$MODE" in
		ipv4)
			run_test_v4
			local top
			top=$(get_top "$TOP_N")
			msg=$(build_message "$net_info" "IPv4" "$top")
			;;
		ipv6)
			run_test_v6
			local top
			top=$(get_top "$TOP_N")
			msg=$(build_message "$net_info" "IPv6" "$top")
			;;
		both)
			run_test_v4
			local top4
			top4=$(get_top "$TOP_N")
			run_test_v6
			local top6
			top6=$(get_top "$TOP_N")
			msg=$(build_message_both "$net_info" "$top4" "$top6")
			;;
		*)
			echolog "错误: 未知 MODE='${MODE}'，应为 ipv4|ipv6|both"
			restore_proxy
			return 1
			;;
	esac

	# 5. 恢复代理 (测试结束，先恢复再推送，否则 TG 无法连通)
	restore_proxy

	# 6. 显示结果到屏幕
	printf '%s\n' "$msg"

	# 7. 推送
	send_telegram "$msg"

	echolog "====== 任务结束 ======"
}

# 快速测速 (cf test)：用 -ip 随机 IP 段 + -n 100 -t 4
# $1 = 是否推送 (1=推送[默认]，0=不推送)
# $2 = (可选) 自定义 CIDR
# $3 = (可选) allip 标志，测试全部 IP
# 流程: 查询网络 -> 测速 -> (可选)推送
run_test_only() {
	local fast_push="${1:-0}"
	local custom_cidr="${2:-}"
	local allip="${3:-}"
	rm -f "$RESULT_FILE"
	echolog "====== 快速测速开始 ======"

	# 1. 检查 cfst
	if ! find_cfst; then
		echolog "错误: 未找到 cfst 二进制"
		return 1
	fi

	# 2. 查询本地网络
	local net_info=""
	if [ "$fast_push" = "1" ]; then
		net_info=$(get_network_info)
		echolog "本地网络: ${net_info}"
	fi

	# 3. 测速 + 取 top
	local msg=""
	local top="" top4="" top6=""
	case "$MODE" in
		ipv4)
			run_fast_test_v4 "$custom_cidr" "$allip"
			top=$(get_top "$TOP_N")
			[ "$fast_push" = "1" ] && msg=$(build_message "$net_info" "IPv4-快速测试" "$top")
			;;
		ipv6)
			run_fast_test_v6 "$custom_cidr" "$allip"
			top=$(get_top "$TOP_N")
			[ "$fast_push" = "1" ] && msg=$(build_message "$net_info" "IPv6-快速测试" "$top")
			;;
		both)
			run_fast_test_v4 "$custom_cidr" "$allip"
			top4=$(get_top "$TOP_N")
			run_fast_test_v6 "$custom_cidr" "$allip"
			top6=$(get_top "$TOP_N")
			[ "$fast_push" = "1" ] && msg=$(build_message_both "$net_info" "$top4" "$top6")
			;;
		*)
			echolog "错误: 未知 MODE='${MODE}'"
			return 1
			;;
	esac

	# 4. 显示结果到屏幕
	echo ""
	case "$MODE" in
		ipv4)
			echo "IPv4 延迟最低的 IP："
			if [ -z "$top" ]; then
				echo "  （无可用 IP）"
			else
				echo "$top" | format_top
			fi
			;;
		ipv6)
			echo "IPv6 延迟最低的 IP："
			if [ -z "$top" ]; then
				echo "  （无可用 IP）"
			else
				echo "$top" | format_top
			fi
			;;
		both)
			echo "IPv4 延迟最低的 IP："
			if [ -z "$top4" ]; then
				echo "  （无可用 IP）"
			else
				echo "$top4" | format_top
			fi
			echo ""
			echo "IPv6 延迟最低的 IP："
			if [ -z "$top6" ]; then
				echo "  （无可用 IP）"
			else
				echo "$top6" | format_top
			fi
			;;
	esac

	# 5. 推送
	if [ "$fast_push" = "1" ] && [ -n "$msg" ]; then
		send_telegram "$msg"
	fi

	echolog "====== 快速测速结束 ======"
}

# 仅推送 (基于已有结果)
# 不测速，无需 disable/restore；但需代理可达，否则跳过推送
run_push_only() {
	local net_info
	net_info=$(get_network_info)
	echolog "本地网络: ${net_info}"
	case "$MODE" in
		ipv4)
			local top
			top=$(get_top "$TOP_N")
			local msg
			msg=$(build_message "$net_info" "IPv4" "$top")
			printf '%s\n' "$msg"
			send_telegram "$msg"
			;;
		ipv6)
			local top
			top=$(get_top "$TOP_N")
			local msg
			msg=$(build_message "$net_info" "IPv6" "$top")
			printf '%s\n' "$msg"
			send_telegram "$msg"
			;;
		both)
			# both 模式下结果文件只保留最后一次测试，按当前结果推送
			local top
			top=$(get_top "$TOP_N")
			local msg
			msg=$(build_message "$net_info" "当前" "$top")
			printf '%s\n' "$msg"
			send_telegram "$msg"
			;;
	esac
}

# ===================== cron 管理 =====================
add_cron() {
	local mode="${1:-$MODE}"
	del_cron
	mkdir -p "$(dirname "$CRON_FILE")"
	echo "${CRON_MINUTE} ${CRON_HOUR} * * * ${SCRIPT_PATH} cron-run ${mode}" >> "$CRON_FILE"
	/etc/init.d/cron restart 2>/dev/null || crontab "$CRON_FILE" 2>/dev/null
	echolog "已开启定时任务: 每天 ${CRON_HOUR}:${CRON_MINUTE} 执行 (模式: ${mode})"
	echolog "  (调用: ${SCRIPT_PATH} cron-run ${mode})"
}

del_cron() {
	if [ -f "$CRON_FILE" ]; then
		sed -i '/cron-run/d' "$CRON_FILE"
		/etc/init.d/cron restart 2>/dev/null || true
	fi
	echolog "已关闭定时任务"
}

show_status() {
	echo "===== Cloudflare 优选 IP 状态 ====="
	echo "脚本路径    : ${SCRIPT_PATH}"
	echo "测试模式    : ${MODE}"
	echo "定时时间    : ${CRON_HOUR}:${CRON_MINUTE} (每天)"
	if [ -f "$CRON_FILE" ] && grep -q 'cron-run' "$CRON_FILE" 2>/dev/null; then
		echo "定时任务    : 已开启"
		grep 'cron-run' "$CRON_FILE" | sed 's/^/  /'
	else
		echo "定时任务    : 未开启"
	fi
	echo "Telegram    : 已开启"
	echo "  Bot Token : $([ -n "$TG_BOT_TOKEN" ] && echo '已配置' || echo '未配置')"
	echo "  Chat ID   : ${TG_CHAT_ID:-(未配置)}"
	echo "  API 地址  : ${TG_API}"
	echo "推送数量    : ${TOP_N}"
	echo "cfst 路径   : ${CFST} ($([ -x "$CFST" ] && echo '存在' || echo '不存在'))"
	echo "结果文件    : ${RESULT_FILE} ($([ -f "$RESULT_FILE" ] && echo '存在' || echo '不存在'))"
	echo "==================================="
}

# ===================== 交互菜单 =====================
# 菜单即用法：无参数时显示交互菜单

show_last_result_simple() {
	if [ -f "$RESULT_FILE" ] && [ -s "$RESULT_FILE" ]; then
		echo "上次测速结果 (延迟最低的 5 个 IP):"
		echo "  IP地址            延迟(ms)"
		echo "  -------------------------------"
		awk -F, 'NR>1 && NF>=5 && $1!="" {printf "  %-15s  %s ms\n", $1, $5}' "$RESULT_FILE" | sort -k2 -n | head -n 5
	else
		echo "暂无结果数据，请先运行测速"
	fi
}

download_ip_lists() {
	rm -f "$IPV4_TXT" "$IPV6_TXT"
	ensure_ip_list v4
	ensure_ip_list v6
	echo "IP 列表更新完成"
}

# 交互式选择 IP 段 (菜单 test 用)
# $1 = mode (ipv4|ipv6|both)
# 输出: 选中的 CIDR (stdout)，空表示随机
# 注意: 交互提示走 stderr，避免被 $() 捕获
select_cidr_interactive() {
	local mode="$1"
	local file=""
	case "$mode" in
		ipv4) file="$IPV4_TXT" ;;
		ipv6) file="$IPV6_TXT" ;;
		*)    file="$IPV4_TXT" ;;
	esac

	# 确保 IP 列表已下载
	case "$mode" in
		ipv4) ensure_ip_list v4 ;;
		ipv6) ensure_ip_list v6 ;;
		both) ensure_ip_list v4 ;;
	esac

	if [ ! -f "$file" ] || [ ! -s "$file" ]; then
		echo ""
		return
	fi

	local tmp_list="/tmp/cf_cidr_sel.$$"
	awk '$0!="" && $0!~/^#/ && $0~/\// {print NR, $0}' "$file" > "$tmp_list"

	local total
	total=$(wc -l < "$tmp_list")
	if [ "$total" -eq 0 ]; then
		rm -f "$tmp_list"
		echo ""
		return
	fi

	# 以下交互输出全部走 stderr，以免被 $(select_cidr_interactive) 捕获
	echo "" >&2
	echo "可用的 IP 段：" >&2
	local show=$((total > 30 ? 30 : total))
	head -n "$show" "$tmp_list" | while read -r n cidr; do
		printf "  %2d) %s\n" "$n" "$cidr" >&2
	done
	if [ "$total" -gt 30 ]; then
		echo "  ... 共 ${total} 个" >&2
	fi

	printf "选择 IP 段 [1-%d，回车随机]: " "$total" >&2
	read -r sel

	local selected=""
	if [ -n "$sel" ]; then
		selected=$(awk -v n="$sel" 'NR==n {print $2}' "$tmp_list" 2>/dev/null)
		if [ -z "$selected" ]; then
			echo "无效选择，将随机选取" >&2
		fi
	fi

	rm -f "$tmp_list"
	# 最终结果走 stdout 作为返回值
	echo "$selected"
}

run_menu() {
	while :; do
		clear 2>/dev/null || true
		echo ""
		echo "=========================================="
		echo "    Cloudflare CDN IP 优选工具"
		echo "=========================================="
		# 状态栏
		local cron_status="关"
		[ -f "$CRON_FILE" ] && grep -q 'cron-run' "$CRON_FILE" 2>/dev/null && cron_status="开"
		local cfst_status="✗"
		[ -x "$CFST" ] && cfst_status="✓"
		echo "  模式: ${MODE}        定时: ${cron_status}        cfst: ${cfst_status}"
		echo "------------------------------------------"
		echo "  1) start     完整流程 (检测→测速→推送)"
		echo "  2) test      快速测速 (默认推送，可选 IP 段 / -allip)"
		echo "  3) push      仅推送已有结果"
		echo "  4) result    查看上次结果"
		echo "  5) mode      切换测速模式 (ipv4/ipv6/both)"
		echo "  6) download  更新 IP 列表"
		echo "  7) status    查看系统状态详情"
		echo "  8) cron      定时任务开关 (当前: ${cron_status})"
		echo "------------------------------------------"
		echo "  0) 退出"
		echo "=========================================="
		printf "请选择 [0-8]: "
		read -r choice
		echo ""
		case "$choice" in
			1|start)
				run_full
				;;
			2|test)
				cidr_input=$(select_cidr_interactive "$MODE")
				allip_flag=""
				if [ -n "$cidr_input" ]; then
					printf "测试全部 IP? (y/n, 默认 n): "
					read -r allip_choice
					[ "$allip_choice" = "y" ] || [ "$allip_choice" = "Y" ] && allip_flag=1
				fi
				run_test_only 1 "$cidr_input" "$allip_flag"
				;;
			3|push)
				run_push_only
				;;
			4|result)
				show_last_result_simple
				;;
			5|mode)
				printf "输入模式 (ipv4/ipv6/both): "
				read -r m
				case "$m" in
					ipv4|ipv6|both)
						MODE="$m"; echo "模式已切换: $MODE"
						# 定时任务已开启时同步更新
						if [ -f "$CRON_FILE" ] && grep -q 'cron-run' "$CRON_FILE" 2>/dev/null; then
							add_cron "$MODE"
							echo "定时任务已同步更新"
						fi
						;;
					*) echo "无效模式，保持: $MODE" ;;
				esac
				;;
			6|download)
				download_ip_lists
				;;
			7|status)
				show_status
				;;
			8|cron)
				if [ -f "$CRON_FILE" ] && grep -q 'cron-run' "$CRON_FILE" 2>/dev/null; then
					del_cron
				else
					add_cron "$MODE"
				fi
				;;
			0|exit|q)
				exit 0
				;;
			*)
				echo "无效选择，请输入 0-8"
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
# start/cron-run/test/push/cron-on 支持 [ipv4|ipv6|both] 第二参数
# test 额外支持 CIDR: cf test [m] [CIDR] [-allip] [no-push]，顺序不限
#   CIDR 如 104.16.0.0/12 或 2606:4700::/32，留空则随机选取
#   -allip 测试 CIDR 段内全部 IP (仅 IPv4)

set_mode_arg() {
	# $1 = 候选模式，合法则设置 MODE
	case "$1" in
		ipv4|ipv6|both) MODE="$1"; return 0 ;;
		*) echo "提示: 忽略未知模式 '$1'，使用默认 ${MODE}"; return 1 ;;
	esac
}

case "${1:-}" in
	start|cron-run)
		[ -n "${2:-}" ] && set_mode_arg "$2"
		run_full
		;;
	test)
		# 解析后续参数: [ipv4|ipv6|both] [CIDR] [no-push] [-allip]，顺序不限
		# CIDR 如 104.16.0.0/12 或 2606:4700::/32，会按格式自动推断 ipv4/ipv6
		fast_push=1
		custom_cidr=""
		allip=""
		shift
		while [ $# -gt 0 ]; do
			case "$1" in
				ipv4|ipv6|both) MODE="$1" ;;
				no-push|-no-push) fast_push=0 ;;
				-allip|allip) allip=1 ;;
				*/*)
					custom_cidr="$1"
					# 根据 CIDR 格式自动推断测试模式
					case "$1" in
						*:*) [ "$MODE" != "ipv4" ] && MODE="ipv6" ;;
						*.*) MODE="ipv4" ;;
					esac
					;;
				*) echo "提示: 忽略未知参数 '$1'" ;;
			esac
			shift
		done
		run_test_only "$fast_push" "$custom_cidr" "$allip"
		;;
	push)
		[ -n "${2:-}" ] && set_mode_arg "$2"
		run_push_only
		;;
	cron-on)
		[ -n "${2:-}" ] && set_mode_arg "$2"
		add_cron "$MODE"
		;;
	cron-off)
		del_cron
		;;
	status)
		show_status
		;;
	download)
		download_ip_lists
		;;
	mode)
		[ -n "${2:-}" ] && set_mode_arg "$2"
		echo "当前模式: $MODE"
		;;
	result)
		show_last_result_simple
		;;
	"")
		run_menu
		;;
	*)
		echo "未知命令: $1"
		echo "用法: $0 {start|test|push|cron-on|cron-off|status|download|mode|result} [ipv4|ipv6|both]"
		exit 1
		;;
esac
