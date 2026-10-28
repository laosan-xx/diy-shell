#!/bin/sh
# desc: IPv6 一键：查原因 / 开 NAT66 / 恢复原样
# ============================================================
# OpenWrt IPv6 一键工具：查原因 / 开启 NAT66 / 恢复原样
#
# 适用：光猫不响应 DHCPv6-PD（WAN 拿不到可委派前缀），
#       内网只能靠 ULA + IPv6 伪装（NAT66）出网的 OpenWrt / ImmortalWrt。
#
# 用法：
#   sh ipv6-nat66.sh             交互菜单
#   sh ipv6-nat66.sh diag        只读诊断（不改任何配置）
#   sh ipv6-nat66.sh fix         一键开启 NAT66
#   sh ipv6-nat66.sh rollback    恢复开启之前的配置
#   sh ipv6-nat66.sh status      快速看当前状态
#
# 远程执行（管道占用了 stdin，必须带动作参数，否则只会跑只读诊断）：
#   ssh root@192.168.99.1 'sh -s diag'     < ipv6-nat66.sh
#   ssh root@192.168.99.1 'sh -s fix'      < ipv6-nat66.sh
#   ssh root@192.168.99.1 'sh -s rollback' < ipv6-nat66.sh
# ============================================================

HOTPLUG=/etc/hotplug.d/iface/99-ipv6-default-route
LAST_BK=/root/.ipv6_last_backup
ORIGIN_BK=/root/.ipv6_origin_backup
FW4_LOG=/tmp/ipv6-fw4check.log

SELF=${0##*/}
case "$SELF" in
    ""|sh|ash|dash|bash) SELF=ipv6-nat66.sh ;;
esac

hr()   { echo "------------------------------------------------------------"; }
say()  { echo; echo ">>> $*"; }
ok()   { echo "[ OK ] $*"; }
warn() { echo "[ !! ] $*"; }
err()  { echo "[ XX ] $*"; }

need_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || { err "需要 root 权限运行"; exit 1; }
}

J() { ifstatus "$1" 2>/dev/null | jsonfilter -e "$2" 2>/dev/null; }

lan_dev() {
    d=$(uci -q get network.lan.device)
    [ -z "$d" ] && d=$(uci -q get network.lan.ifname)
    [ -z "$d" ] && d=br-lan
    printf '%s' "$d"
}

wan_dev() {
    d=$(J wan '@.l3_device')
    [ -z "$d" ] && d=$(J wan6 '@.l3_device')
    [ -z "$d" ] && d=$(uci -q get network.wan.device)
    [ -z "$d" ] && d=$(uci -q get network.wan.ifname)
    [ -z "$d" ] && d=$(ip -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
    [ -z "$d" ] && d=eth0
    printf '%s' "$d"
}

# 找名为 wan 的 firewall zone（找不到就退回 @zone[1]）
find_wan_zone() {
    z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'$/\1/p" | head -n 1)
    [ -z "$z" ] && z="@zone[1]"
    printf '%s' "$z"
}

# ULA 合法性：fd::::/48 这种会让 netifd 解析失败、br-lan 起不来
valid_ula() {
    case "$1" in
        ""|*":::"*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^f[cd][0-9a-f]{0,2}(:[0-9a-f]{0,4}){0,7}::/[0-9]{1,3}$'
}

# ============================================================
# 1. 诊断（只读）
# ============================================================
diag() {
    FINDINGS=""
    ADVICE=""
    finding() { FINDINGS="$FINDINGS
$1"; }
    advise() { ADVICE="$ADVICE
$1"; }

    echo
    echo "==================== IPv6 诊断（只读） ===================="
    [ -f /etc/openwrt_release ] && . /etc/openwrt_release && echo "固件：$DISTRIB_DESCRIPTION"

    LD=$(lan_dev)
    WD=$(wan_dev)

    say "1. wan6 状态"
    echo "up=$(J wan6 '@.up')  proto=$(J wan6 '@.proto')"
    echo "WAN 设备=$WD   LAN 设备=$LD"

    say "2. 上游前缀（PD）—— 决定要不要用 NAT66"
    PFX=$(J wan6 '@.ipv6-prefix[*].address')
    if [ -z "$PFX" ]; then
        echo "没有拿到任何可委派前缀"
        finding "[ !! ] 光猫没有下发 PD 前缀 -> NAT66 是当前可行的方案"
    else
        echo "前缀：$PFX"
        finding "[ OK ] 上游有 PD 前缀 -> 原生 IPv6 才是正解，不需要 NAT66"
        advise "有 PD 时优先做原生下发：wan6 不设 reqprefix=no，lan ip6assign=64"
    fi

    say "3. wan6 请求参数"
    uci show network.wan6 2>/dev/null | grep -E 'reqprefix|reqaddress|proto|device' | sed 's/^/  /'
    RP=$(uci -q get network.wan6.reqprefix)
    case "$RP" in
        no|disabled)
            finding "[ XX ] wan6.reqprefix=$RP -> 路由器根本没请求前缀"
            advise "uci set network.wan6.reqprefix=auto && uci commit network"
            ;;
    esac

    say "4. LAN 前缀分配与地址"
    A=$(J lan '@.ipv6-prefix-assignment[*].address')
    echo "ipv6-prefix-assignment: ${A:-(空)}"
    ip -6 addr show dev "$LD" 2>/dev/null | grep inet6 | sed 's/^/  /'

    say "5. 内网 ULA 前缀"
    ULA=$(uci -q get network.globals.ula_prefix)
    echo "ula_prefix=${ULA:-(空)}"
    if [ -z "$ULA" ]; then
        finding "[ !! ] 没有 ula_prefix，NAT66 没有内网地址来源"
        advise "执行 fix 会自动生成合法 ULA"
    elif valid_ula "$ULA"; then
        finding "[ OK ] ULA 前缀格式正常：$ULA"
    else
        finding "[ XX ] ULA 前缀非法：$ULA（netifd 解析失败，br-lan 会起不来）"
        advise "执行 fix 会自动纠正为合法前缀"
    fi

    say "6. LAN 通告（RA / DHCPv6）"
    RA=$(uci -q get dhcp.lan.ra)
    DV=$(uci -q get dhcp.lan.dhcpv6)
    RAD=$(uci -q get dhcp.lan.ra_default)
    echo "ra=${RA:-?}  dhcpv6=${DV:-?}  ra_default=${RAD:-未设置(默认0)}"
    [ "$RA" != "server" ] && finding "[ !! ] dhcp.lan.ra=${RA:-空} -> LAN 没在发 RA，客户端拿不到地址"
    [ "$RAD" != "1" ] && {
        finding "[ XX ] ra_default=${RAD:-0} -> 只有 ULA 没有公网前缀时 odhcpd 拒发默认路由，客户端有地址没网关"
        advise "uci set dhcp.lan.ra_default=1"
    }
    [ "$(uci -q get dhcp.wan6.ignore)" != "1" ] && finding "[ !! ] dhcp.wan6.ignore 不是 1 -> 可能在 WAN 上乱发 RA/DHCPv6"

    say "7. 出口伪装 masq6"
    Z=$(find_wan_zone)
    M=$(uci -q get "firewall.$Z.masq6")
    echo "WAN zone=$Z  masq6=${M:-(空)}"
    if [ "$M" = "1" ]; then
        finding "[ OK ] masq6 已开启，内网 ULA 会被伪装成 WAN 的 IPv6 出网"
    elif [ -z "$M" ]; then
        finding "[ !! ] masq6 未开启 -> 内网 ULA 出不去"
        advise "执行 fix 会开启 masq6"
    else
        finding "[ XX ] masq6 值非法：'$M'（必须恰好是 1，不能带引号）"
        advise "非法 masq6 会让 fw4 生成规则集失败、整套防火墙卸载，表现为能 ping 网关但上不了网"
        advise "立刻执行 fix 或 rollback"
    fi

    say "8. IPv6 默认路由（关键）"
    ip -6 route show default 2>/dev/null | sed 's/^/  /'
    TOTAL=$(ip -6 route show default 2>/dev/null | wc -l | tr -d ' ')
    UN=$(ip -6 route show default 2>/dev/null | grep -v ' from ' | wc -l | tr -d ' ')
    if [ "${TOTAL:-0}" = "0" ]; then
        finding "[ XX ] 完全没有 IPv6 默认路由 -> 内网 v6 必然不通"
        advise "执行 fix 会装 hotplug 自动补默认路由"
    elif [ "${UN:-0}" = "0" ]; then
        finding "[ XX ] 默认路由全是「源限定」的（带 from）-> 内网 fd00:: 源查表失败，Network unreachable"
        advise "执行 fix 会补一条不带 from 的 metric 1024 默认路由"
    else
        finding "[ OK ] 存在不限源的默认路由"
    fi

    say "9. 默认路由 hotplug"
    if [ -x "$HOTPLUG" ]; then
        echo "已安装：$HOTPLUG"
        finding "[ OK ] hotplug 已安装"
    elif [ -f "$HOTPLUG" ]; then
        warn "存在但没有执行权限：$HOTPLUG"
        advise "chmod +x $HOTPLUG"
    else
        finding "[ !! ] 未安装 $HOTPLUG -> 路由器重启后默认路由会丢，v6 又断"
        advise "执行 fix 会自动安装"
    fi

    say "10. 防火墙规则集是否正常加载"
    N=$(nft list ruleset 2>/dev/null | wc -l | tr -d ' ')
    echo "nft 规则行数：${N:-0}（正常约 180~220）"
    if command -v fw4 >/dev/null 2>&1; then
        if fw4 check >"$FW4_LOG" 2>&1; then
            echo "fw4 check：通过"
        else
            err "fw4 check：失败"
            head -n 15 "$FW4_LOG" | sed 's/^/  /'
            finding "[ XX ] fw4 规则检查失败 -> 防火墙没加载，LAN->WAN 全部落到 REJECT"
            advise "重点看 masq6 有没有被写成带引号的 '1'，跑 fix 或 rollback 修复"
        fi
    fi
    if [ "${N:-0}" -lt 60 ] 2>/dev/null; then
        finding "[ XX ] nft 规则行数偏少（${N:-0}），防火墙很可能没加载"
    fi

    say "11. odhcpd"
    if pgrep -f odhcpd >/dev/null 2>&1; then
        echo "运行中"
        finding "[ OK ] odhcpd 运行中"
    else
        echo "未运行"
        finding "[ XX ] odhcpd 没运行 -> LAN 不发 RA/DHCPv6"
        advise "/etc/init.d/odhcpd restart"
    fi

    say "12. 上游邻居"
    ip -6 neigh show dev "$WD" 2>/dev/null | head -n 5 | sed 's/^/  /'

    echo
    echo "==================== 结论 ===================="
    [ -n "$FINDINGS" ] && printf '%s\n' "$FINDINGS"
    if [ -n "$ADVICE" ]; then
        echo
        echo "建议："
        printf '%s\n' "$ADVICE"
    fi
    echo
    echo "下一步：sh $SELF fix   一键开启 NAT66"
    echo "        sh $SELF status 快速看状态"
}

# ============================================================
# 2. 备份 / 回滚点
# ============================================================
do_backup() {
    bk_new="/root/ipv6bak-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk_new"
    cp /etc/config/network /etc/config/dhcp /etc/config/firewall "$bk_new"/ 2>/dev/null
    if [ -f "$HOTPLUG" ]; then
        echo exists >"$bk_new/hotplug.state"
    else
        echo absent >"$bk_new/hotplug.state"
    fi
    echo "$bk_new" >"$LAST_BK"
    echo "本次备份：$bk_new"

    # ORIGIN 只记录第一次开启前的状态，重复执行 fix 不会把它覆盖成"已开启"的样子
    if [ -f "$ORIGIN_BK" ] && [ -d "$(cat "$ORIGIN_BK" 2>/dev/null)" ]; then
        BK=$(cat "$ORIGIN_BK")
        echo "原始备份：$BK（回滚以它为准）"
    else
        BK="$bk_new"
        echo "$BK" >"$ORIGIN_BK"
        echo "已记录原始备份，回滚将回到这个状态"
    fi
}

pick_backup() {
    b="$1"
    if [ -z "$b" ] && [ -f "$ORIGIN_BK" ]; then
        b=$(cat "$ORIGIN_BK" 2>/dev/null)
    fi
    if [ -z "$b" ] || [ ! -d "$b" ]; then
        b=$(cat "$LAST_BK" 2>/dev/null)
    fi
    if [ -z "$b" ] || [ ! -d "$b" ]; then
        b=$(ls -d /root/ipv6bak-* 2>/dev/null | head -n 1)
    fi
    printf '%s' "$b"
}

# ============================================================
# 3. 默认路由 hotplug（内嵌，单文件即可用）
# ============================================================
install_hotplug() {
    mkdir -p /etc/hotplug.d/iface
    cat >"$HOTPLUG" <<'HPEOF'
#!/bin/sh
# ============================================================
# wan6 上线后补一条"不限源"的 IPv6 默认路由
#
# netifd 在 DHCPv6 单地址（noprefixroute）场景下只会生成：
#   default from <WAN地址> via fe80::x dev wan metric 512
# 这是"源限定"路由，内网 fd00:: 源的流量查表匹配不上，
# 内核直接判 Network unreachable，客户端 IPv6 全废。
# 所以这里补一条不带 from 的默认路由，重启后自动重建。
#
# 由 ipv6-nat66.sh 安装，删除即恢复原行为。
# ============================================================

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
	wan | wan6 | wan_6 | pppoe-wan) ;;
	*) exit 0 ;;
esac

DEV="${DEVICE:-}"
[ -z "$DEV" ] && DEV=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
[ -z "$DEV" ] && DEV=$(ip -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
[ -z "$DEV" ] && exit 0

i=0
while [ $i -lt 15 ]; do
	GW=$(ip -6 route show default dev "$DEV" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -n 1)
	[ -z "$GW" ] && GW=$(ip -6 neigh show dev "$DEV" 2>/dev/null | awk '/router/ {print $1; exit}')
	if [ -n "$GW" ]; then
		if ip -6 route replace default via "$GW" dev "$DEV" metric 1024 2>/dev/null; then
			logger -t ipv6-default "默认路由已就位 via $GW dev $DEV"
			exit 0
		fi
	fi
	i=$((i + 1))
	sleep 1
done

ip -6 route replace default via fe80::1 dev "$DEV" metric 1024 2>/dev/null
logger -t ipv6-default "没探测到上游网关，使用 fe80::1 兜底 (dev $DEV)"
HPEOF
    chmod +x "$HOTPLUG"
}

# ============================================================
# 4. 重启服务（后台执行，避免 SSH 断开中断脚本）
# ============================================================
apply_services() {
    cat >/tmp/ipv6-apply.sh <<'APPLY'
#!/bin/sh
/etc/init.d/network restart >/dev/null 2>&1
sleep 2
[ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd restart >/dev/null 2>&1
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall restart >/dev/null 2>&1
touch /tmp/ipv6-apply.done
APPLY
    chmod +x /tmp/ipv6-apply.sh
    rm -f /tmp/ipv6-apply.done
    nohup /tmp/ipv6-apply.sh >/tmp/ipv6-apply.log 2>&1 &
    echo "服务正在后台重启（SSH 可能短暂断开），等它跑完再验证..."
    i=0
    while [ $i -lt 60 ]; do
        [ -f /tmp/ipv6-apply.done ] && break
        sleep 1
        i=$((i + 1))
    done
    [ -f /tmp/ipv6-apply.done ] || warn "等待超时，服务可能还在重启；稍后执行 status 复查"
}

# ============================================================
# 5. 验证
# ============================================================
verify() {
    say "验证结果"
    UN=$(ip -6 route show default 2>/dev/null | grep -v ' from ')
    if [ -n "$UN" ]; then
        ok "默认路由：$UN"
    else
        err "没有不限源的默认路由 —— hotplug 可能没触发，执行 /etc/init.d/network restart 后再看"
    fi

    LD=$(lan_dev)
    if ip -6 addr show dev "$LD" 2>/dev/null | grep -q 'inet6 fd'; then
        ok "LAN($LD) 已有 ULA 地址"
        ip -6 addr show dev "$LD" 2>/dev/null | grep 'inet6 fd' | sed 's/^/        /'
    else
        err "LAN($LD) 没有 ULA 地址 —— 检查 ula_prefix / ip6assign"
    fi

    M=$(uci -q get "firewall.$(find_wan_zone).masq6")
    [ "$M" = "1" ] && ok "masq6=1" || err "masq6=${M:-空}"

    N=$(nft list ruleset 2>/dev/null | wc -l | tr -d ' ')
    if [ "${N:-0}" -gt 60 ] 2>/dev/null; then
        ok "防火墙规则已加载（${N} 行）"
    else
        err "防火墙规则异常（${N:-0} 行）—— 跑 fw4 check 看原因"
    fi

    [ -x "$HOTPLUG" ] && ok "默认路由 hotplug 已安装" || err "hotplug 未安装"

    echo
    echo "客户端侧验证："
    echo "  ping -6 2400:3200::1"
    echo "  curl -6 https://ipv6.baidu.com"
    echo
    echo "注意：NAT66 下外网无法主动连入内网设备。"
    echo "      要让 NAS 等被外网访问，只能光猫桥接 + PPPoE 拿到 PD 做原生 v6。"
}

# ============================================================
# 6. 一键开启 NAT66
# ============================================================
fix() {
    need_root
    [ -f /etc/config/network ] || { err "不是 OpenWrt 环境（/etc/config/network 不存在）"; exit 1; }

    echo
    echo "==================== 一键开启 NAT66 ===================="
    echo "将修改 network / dhcp / firewall，并安装默认路由 hotplug；"
    echo "随后重启网络服务，SSH 会短暂断开。配置会先备份，可随时 rollback。"
    echo
    do_backup

    # ---------- 1. ULA ----------
    say "1/6 内网 ULA 前缀"
    ULA=$(uci -q get network.globals.ula_prefix)
    if valid_ula "$ULA"; then
        echo "沿用现有：$ULA"
    else
        [ -n "$ULA" ] && warn "现有 ula_prefix 非法（$ULA），重新生成"
        # 不用 od：精简固件普遍没有，会生成 fd::::/48 这种非法前缀
        H=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-10)
        [ -z "$H" ] && H=$(date +%s | md5sum 2>/dev/null | cut -c1-10)
        # 兜底：uuid 与 md5sum 都不可用的极端精简固件，给一个固定的合法前缀
        case "$H" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
            *) H=1234567890 ;;
        esac
        ULA="fd$(printf '%s' "$H" | cut -c1-2):$(printf '%s' "$H" | cut -c3-6):$(printf '%s' "$H" | cut -c7-10)::/48"
        valid_ula "$ULA" || ULA="fd12:3456:789a::/48"
        uci set network.globals.ula_prefix="$ULA"
        echo "已生成：$ULA"
    fi

    # ---------- 2. LAN 用该前缀 ----------
    say "2/6 LAN 使用该前缀（/64）"
    uci set network.lan.ip6assign='64'
    uci set network.lan.ip6class='local'
    uci -q delete network.lan.ip6hint
    echo "ip6assign=64 ip6class=local"

    # ---------- 3. LAN 通告 ----------
    say "3/6 打开 LAN 的 RA 与 DHCPv6"
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra_management='1'
    # ra_default 必须 1：只有 ULA 没有公网前缀时，odhcpd 默认把 ra_lifetime 置 0，
    # 即拒绝下发默认路由，客户端拿到 fd00:: 地址却没有网关。
    uci set dhcp.lan.ra_default='1'
    uci set dhcp.lan.ra_lifetime='1800'
    uci -q delete dhcp.lan.ndp
    uci -q delete dhcp.lan.ignore
    uci set dhcp.wan6=dhcp 2>/dev/null
    uci set dhcp.wan6.interface='wan6'
    uci set dhcp.wan6.ignore='1'
    echo "ra=server dhcpv6=server ra_default=1 ra_lifetime=1800"

    # ---------- 4. masq6 ----------
    say "4/6 打开 WAN 出口伪装 masq6"
    Z=$(find_wan_zone)
    echo "WAN zone = $Z"
    uci -q delete "firewall.$Z.masq6" 2>/dev/null
    # 值绝不能带引号：写成 masq6='1' 会把引号一起存进去，
    # 非法值让 fw4 生成 nft 规则集失败，整套防火墙不加载 -> 全内网断网。
    uci set "firewall.$Z.masq6=1"
    V=$(uci -q get "firewall.$Z.masq6")
    if [ "$V" != "1" ]; then
        err "masq6 写入异常（值为 '$V'），中止，避免防火墙整包失效"
        exit 1
    fi
    echo "masq6 = $V"

    # ---------- 5. 提交 + 防火墙自检 ----------
    say "5/6 提交配置并自检防火墙规则"
    uci commit network
    uci commit dhcp
    uci commit firewall
    if command -v fw4 >/dev/null 2>&1; then
        if ! fw4 check >"$FW4_LOG" 2>&1; then
            err "fw4 规则检查失败，为避免整套防火墙失效，正在还原 firewall 配置"
            cp "$bk_new/firewall" /etc/config/firewall 2>/dev/null && uci commit firewall
            head -n 20 "$FW4_LOG" | sed 's/^/  /'
            err "已中止，network / dhcp 的改动未生效。建议执行 rollback 彻底还原"
            exit 1
        fi
        ok "fw4 check 通过"
    else
        warn "没有 fw4 命令（老版本防火墙），跳过自检"
    fi

    # ---------- 6. hotplug + 应用 ----------
    say "6/6 安装默认路由 hotplug 并重启服务"
    install_hotplug
    ok "已安装 $HOTPLUG"
    echo "$(date +%s)" >/root/.ipv6_nat66_enabled

    apply_services
    verify

    echo
    echo "回滚：sh $SELF rollback"
}

# ============================================================
# 7. 恢复原样
# ============================================================
rollback() {
    need_root
    b=$(pick_backup "$1")
    if [ -z "$b" ] || [ ! -d "$b" ]; then
        err "找不到备份目录，无法回滚"
        echo "可用备份："
        ls -d /root/ipv6bak-* 2>/dev/null | sed 's/^/  /'
        echo "手动指定：sh $SELF rollback /root/ipv6bak-xxxxxx"
        exit 1
    fi

    echo
    echo "==================== 恢复原样 ===================="
    echo "使用备份：$b"
    for f in network dhcp firewall; do
        if [ -f "$b/$f" ]; then
            cp "$b/$f" "/etc/config/$f"
            echo "  已恢复 /etc/config/$f"
        else
            echo "  跳过 $f（备份里没有）"
        fi
    done

    st=$(cat "$b/hotplug.state" 2>/dev/null)
    if [ "$st" = "absent" ]; then
        rm -f "$HOTPLUG"
        echo "  已移除 $HOTPLUG（备份前本来就没有）"
    else
        [ -f "$HOTPLUG" ] && echo "  保留 $HOTPLUG（备份前已存在）"
    fi
    rm -f /root/.ipv6_nat66_enabled

    apply_services
    echo
    ok "已回滚，网络服务已重启"
    echo "（原始备份记录保留在 $ORIGIN_BK，如需彻底清除：rm -f $ORIGIN_BK $LAST_BK）"
}

# ============================================================
# 8. 快速状态
# ============================================================
status() {
    Z=$(find_wan_zone)
    M=$(uci -q get "firewall.$Z.masq6")
    ULA=$(uci -q get network.globals.ula_prefix)
    RAD=$(uci -q get dhcp.lan.ra_default)
    UN=$(ip -6 route show default 2>/dev/null | grep -v ' from ' | head -n 1)
    N=$(nft list ruleset 2>/dev/null | wc -l | tr -d ' ')

    echo
    say "当前 IPv6 状态"
    echo "  NAT66 / masq6 : ${M:-(空)}"
    echo "  ULA 前缀      : ${ULA:-(空)}"
    echo "  ra_default    : ${RAD:-未设置}"
    echo "  默认路由      : ${UN:-无}"
    echo "  hotplug       : $([ -x "$HOTPLUG" ] && echo 已安装 || echo 未安装)"
    echo "  nft 规则行数  : ${N:-0}"
    echo "  odhcpd        : $(pgrep -f odhcpd >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
    echo

    if [ "$M" = "1" ] && [ -n "$UN" ] && [ -x "$HOTPLUG" ]; then
        ok "NAT66 配置完整"
    else
        warn "NAT66 配置不完整，建议先 diag 查原因"
    fi
    if [ "${N:-0}" -lt 60 ] 2>/dev/null; then
        err "防火墙规则集异常偏少，所有转发可能被 REJECT"
    fi
}

# ============================================================
# 9. 菜单 / 入口
# ============================================================
usage() {
    cat <<EOF
OpenWrt IPv6 一键工具

用法：sh $SELF [动作]

  diag       只读诊断，查 IPv6 不通的原因（不改任何配置）
  fix        一键开启 NAT66（ULA + RA + masq6 + 默认路由 hotplug）
  rollback   恢复开启之前的配置（默认用最早的备份）
  status     快速看当前状态
  （不带参数） 交互菜单

远程执行：
  ssh root@192.168.99.1 'sh -s diag' < ipv6-nat66.sh
  ssh root@192.168.99.1 'sh -s fix'  < ipv6-nat66.sh
EOF
}

confirm_fix() {
    echo
    echo "将修改 network / dhcp / firewall 并重启网络服务，SSH 会短暂断开。"
    echo "配置会先备份，可随时用 rollback 还原。"
    printf "继续？[y/N]: "
    read -r a
    case "$a" in
        y | Y | yes | YES) fix ;;
        *) echo "已取消" ;;
    esac
}

confirm_rollback() {
    b=$(pick_backup "")
    echo
    echo "将恢复到备份：${b:-（没找到）}"
    printf "继续？[y/N]: "
    read -r a
    case "$a" in
        y | Y | yes | YES) rollback ;;
        *) echo "已取消" ;;
    esac
}

menu() {
    while :; do
        echo
        echo "=============== OpenWrt IPv6 工具 ==============="
        echo "  1) 查原因    只读诊断，不改配置"
        echo "  2) 开启 NAT66 内网 ULA + 出口伪装 + 默认路由"
        echo "  3) 恢复原样  还原到开启之前的配置"
        echo "  4) 看状态    快速检查现在是否正常"
        echo "  0) 退出"
        printf "请选择 [0-4]: "
        read -r ch || break
        case "$ch" in
            1) diag ;;
            2) confirm_fix ;;
            3) confirm_rollback ;;
            4) status ;;
            0 | q | Q | "") break ;;
            *) echo "无效选择" ;;
        esac
    done
}

case "${1:-}" in
    diag | check | d) diag ;;
    fix | nat | apply) fix ;;
    rollback | restore | undo | r) rollback "${2:-}" ;;
    status | st | s) status ;;
    -h | --help | help) usage ;;
    "" | menu | m)
        if [ -t 0 ]; then
            menu
        else
            echo "检测到非交互环境（stdin 被脚本管道占用），自动执行只读诊断。"
            echo "远程修复请用：ssh root@路由器 'sh -s fix' < ipv6-nat66.sh"
            diag
        fi
        ;;
    *)
        usage
        exit 1
        ;;
esac
