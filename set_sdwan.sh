#!/usr/bin/env bash
# 自动化配置本端机器与中国内地机器之间的SNAT与策略路由
# 需在本端机器(root)执行，脚本将：
# 1. 读取两端网卡信息
# 2. 在本端机器上开启IPv4转发并创建仅包含SNAT的nft规则
# 3. 通过SSH登录中国内地机器，设置默认路由经由本端SD-WAN并为eth0维持原网关的策略路由
# 4. 为nft与中国内地侧路由分别创建systemd持久化服务

set -euo pipefail
export LC_ALL=C

LOG_PREFIX="[HaloCloud组网脚本]"

info() {
  echo -e "${LOG_PREFIX} $*"
}

warn() {
  echo -e "${LOG_PREFIX} [警告] $*" >&2
}

die() {
  echo -e "${LOG_PREFIX} [错误] $*" >&2
  exit 1
}

on_error() {
  local exit_code=$1
  local line_no=$2
  if [[ $exit_code -ne 0 ]]; then
    warn "脚本在第${line_no}行失败，退出码=${exit_code}"
  fi
}

trap 'on_error $? $LINENO' ERR

PKG_MGR=""
PKG_INSTALL_CMD=()
PKG_UPDATED=0

A_IP=""
A_SSH_PORT=22
A_PASS=""
A_HOSTNAME=""
A_NIC_INFO=""
A_ADDR_LIST=()
A_SD_WAN_IF=""
A_ETH0_IP=""
A_ETH0_GW=""
A_ETH0_HAS_IPV4=0
A_ETH0_IP6=""
A_ETH0_IP_LIST=()    # 新增：eth0上所有IPv4地址列表
A_ETH1_IP=""
A_ETH1_GW=""
A_ETH1_HAS_IPV4=0
A_ETH1_IP6=""

# IPv6 ULA 地址配置（用于 SD-WAN IPv6 出口）
IPV6_ULA_PREFIX="fd00:ab::"
B_ETH1_IPV6_ULA=""   # 本端 eth1 ULA 地址
A_ETH1_IPV6_ULA=""   # 内地端 eth1 ULA 地址

# IPv6 出口检测
B_WAN_IPV6=""        # 本端 WAN 口的 IPv6 地址
B_WAN_IPV6_GW=""     # 本端 WAN 口的 IPv6 网关
HAS_WAN_IPV6=0       # 本端 WAN 是否有 IPv6
SIT_TUNNEL_NAME="sit-ab"  # SIT 隧道名称（IPv6 over IPv4）

LOCAL_HOSTNAME=""
LOCAL_NIC_INFO=""
B_SD_WAN_IF=""
B_SD_WAN_IP=""
B_WAN_IF=""
B_WAN_IP=""
B_WAN_GW=""

NFT_SCRIPT_PATH="/usr/local/sbin/ab-nft-restore.sh"
NFT_SERVICE_PATH="/etc/systemd/system/ab-nft.service"
SYSCTL_FILE="/etc/sysctl.d/99-ab-nat.conf"

REMOTE_ROUTE_SCRIPT="/usr/local/sbin/ab-route-setup.sh"
REMOTE_ROUTE_SERVICE="/etc/systemd/system/ab-route-setup.service"
AUTO_UPGRADE_STATE_FILE="/etc/ab_auto_upgrade_state"

validate_ipv4() {
  local ip=$1
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "IP地址 $ip 格式不正确"
  fi
  IFS='.' read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    if ((octet < 0 || octet > 255)); then
      die "IP地址 $ip 含非法段"
    fi
  done
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "请使用root权限运行此脚本"
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_INSTALL_CMD=(apt-get install -y)
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_INSTALL_CMD=(dnf install -y)
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    PKG_INSTALL_CMD=(yum install -y)
  else
    die "无法识别包管理器(仅支持apt/dnf/yum)"
  fi
}

update_pkg_index_if_needed() {
  if [[ $PKG_UPDATED -eq 1 ]]; then
    return
  fi
  case "$PKG_MGR" in
    apt)
      info "刷新apt软件源"
      apt-get update -y >/dev/null
      ;;
    dnf|yum)
      # dnf/yum安装时会自动处理元数据
      :
      ;;
  esac
  PKG_UPDATED=1
}

ensure_package() {
  local pkg=$1
  local binary=$2
  if command -v "$binary" >/dev/null 2>&1; then
    return
  fi
  update_pkg_index_if_needed
  info "安装依赖包: $pkg"
  "${PKG_INSTALL_CMD[@]}" "$pkg" >/dev/null
}

prompt_inputs() {
  read -r -p "请输入中国内地机器 SD-WAN 的IP地址: " A_IP
  validate_ipv4 "$A_IP"

  read -r -p "请输入中国内地机器 SSH 端口 [回车默认 22]: " A_SSH_PORT
  A_SSH_PORT=${A_SSH_PORT:-22}
  if ! [[ "$A_SSH_PORT" =~ ^[0-9]+$ ]] || ((A_SSH_PORT < 1 || A_SSH_PORT > 65535)); then
    die "SSH端口 $A_SSH_PORT 非法（必须是 1-65535）"
  fi

  read -r -s -p "请输入中国内地机器 root 密码: " A_PASS
  echo ""
  if [[ -z $A_PASS ]]; then
    die "密码不能为空"
  fi
}

ssh_remote() {
  local raw_cmd=$1
  local quoted=""
  printf -v quoted '%q' "$raw_cmd"
  sshpass -p "$A_PASS" ssh \
    -p "$A_SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o LogLevel=ERROR \
    -o ConnectTimeout=15 \
    "root@${A_IP}" "LANG=C bash -c $quoted"
}

check_sdwan_connectivity() {
  info "预检：检测SD-WAN是否连通（ping $A_IP）..."

  local count=3
  local timeout=2

  if ping -c "$count" -W "$timeout" "$A_IP" >/dev/null 2>&1; then
    info "SD-WAN 连通性正常 ✅"
    return 0
  fi

  warn "SD-WAN 不通 ❌（无法ping通 $A_IP），已停止执行后续配置。"
  cat <<EOF

SD-WAN 当前不通，请按以下步骤操作：

1) 登录官网 → 进入【SD-WAN】页面，点击右侧【选择机器】
2) 在弹窗中，将【本端机器】和【对端机器】全部清空
3) 点击【确定】保存
4) 等待10秒左右，再次点击【选择机器】，重新选择本端/对端并保存
5) 等待配置下发完成后，重新运行本脚本

EOF
  exit 2
}

test_remote() {
  info "校验与中国内地机器的SSH连接..."
  if ! ssh_remote "true" >/dev/null 2>&1; then
    die "无法通过SSH连接中国内地机器，请确认IP/密码/端口"
  fi
}

disable_remote_auto_upgrade() {
  # 检查是否为 Debian 系统
  if ! ssh_remote "test -f /etc/debian_version" >/dev/null 2>&1; then
    info "中国内地机器非 Debian 系统，跳过自动 apt upgrade 服务处理"
    return 0
  fi

  # 检查是否已经禁用过
  if ssh_remote "test -f $AUTO_UPGRADE_STATE_FILE" >/dev/null 2>&1; then
    info "检测到 ${AUTO_UPGRADE_STATE_FILE} 标签，自动 apt upgrade 服务此前已被禁用"
    return 0
  fi

  info "禁用自动 apt upgrade 服务，防止配置路由时被干扰..."
  if ssh_remote "bash -s '$AUTO_UPGRADE_STATE_FILE'" <<'EOF'
state_file="$1"
set -euo pipefail
units=(apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service unattended-upgrades.service unattended-upgrades.timer)
tmp=$(mktemp)
touched=0
for unit in "${units[@]}"; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    touched=1
    state=$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)
    printf '%s=%s\n' "$unit" "$state" >>"$tmp"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi
done
if [ "$touched" -eq 1 ]; then
  mv "$tmp" "$state_file"
else
  rm -f "$tmp"
fi
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
  then
    info "已禁用自动 apt upgrade 服务，并记录状态至 ${AUTO_UPGRADE_STATE_FILE}"
  else
    warn "禁用自动 apt upgrade 服务失败，请手动检查"
    return 1
  fi
}

restore_remote_auto_upgrade() {
  # 检查是否有状态文件
  if ! ssh_remote "test -f $AUTO_UPGRADE_STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  info "恢复自动 apt upgrade 服务状态..."
  if ssh_remote "bash -s '$AUTO_UPGRADE_STATE_FILE'" <<'EOF'
state_file="$1"
set -euo pipefail
if [ ! -f "$state_file" ]; then
  exit 0
fi
while IFS='=' read -r unit state; do
  [ -z "$unit" ] && continue
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    continue
  fi
  case "$state" in
    enabled|enabled-runtime)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      systemctl enable "$unit" >/dev/null 2>&1 || true
      systemctl start "$unit" >/dev/null 2>&1 || true
      ;;
    disabled|disabled-runtime)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      systemctl disable "$unit" >/dev/null 2>&1 || true
      ;;
    masked)
      systemctl mask "$unit" >/dev/null 2>&1 || true
      ;;
    static|unknown|*)
      systemctl unmask "$unit" >/dev/null 2>&1 || true
      ;;
  esac
done < "$state_file"
rm -f "$state_file"
systemctl daemon-reload >/dev/null 2>&1 || true
EOF
  then
    info "已根据 ${AUTO_UPGRADE_STATE_FILE} 恢复自动 apt upgrade 服务状态"
  else
    warn "恢复自动 apt upgrade 服务状态失败，请手动检查 ${AUTO_UPGRADE_STATE_FILE}"
    return 1
  fi
}

gather_local_info() {
  LOCAL_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
  LOCAL_NIC_INFO=$(ip -br addr show | while IFS= read -r line; do
    case "$line" in
      lo[[:space:]]*) continue ;;
      *) printf '%s\n' "$line" ;;
    esac
  done)

  # 自动检测到中国内地机器的路由（作为默认推荐）
  local auto_if="" auto_ip=""
  local route_line
  if route_line=$(ip route get "$A_IP" 2>/dev/null); then
    auto_if=$(awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route_line")
    auto_ip=$(awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<<"$route_line")
  fi

  # 列出所有网络接口供用户选择 SD-WAN 接口
  local interfaces=() iface_ips=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local iface
    iface=$(awk '{print $1}' <<<"$line")
    [[ -z "$iface" ]] && continue
    local addrs
    addrs=$(awk '{$1=$2=""; sub(/^[[:space:]]+/,""); print}' <<<"$line")
    interfaces+=("$iface")
    iface_ips+=("$addrs")
  done <<<"$LOCAL_NIC_INFO"

  if [[ ${#interfaces[@]} -eq 0 ]]; then
    die "未检测到任何网络接口"
  fi

  echo ""
  info "检测到以下网络接口："
  local default_idx=0
  for i in "${!interfaces[@]}"; do
    local marker=""
    if [[ -n "$auto_if" && "${interfaces[$i]}" == "$auto_if" ]]; then
      marker=" ← 自动检测到的SD-WAN接口"
      default_idx=$((i+1))
    fi
    printf "  %d) %-12s %s%s\n" "$((i+1))" "${interfaces[$i]}" "${iface_ips[$i]}" "$marker"
  done
  echo ""

  local prompt_text
  if [[ $default_idx -gt 0 ]]; then
    prompt_text="请选择本端 SD-WAN 接口 [回车默认 ${default_idx} - ${auto_if}]: "
  else
    prompt_text="请选择本端 SD-WAN 接口 (输入编号): "
  fi

  local choice
  read -r -p "$prompt_text" choice
  if [[ -z $choice ]]; then
    if [[ $default_idx -gt 0 ]]; then
      choice=$default_idx
    else
      die "未选择SD-WAN接口"
    fi
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#interfaces[@]})); then
    die "选择无效（请输入 1-${#interfaces[@]}）"
  fi

  B_SD_WAN_IF="${interfaces[$((choice-1))]}"
  local sd_wan_cidr
  sd_wan_cidr=$(ip -o -4 addr show dev "$B_SD_WAN_IF" | awk '{print $4}' | head -n1)
  if [[ -z $sd_wan_cidr ]]; then
    die "所选接口 $B_SD_WAN_IF 无IPv4地址"
  fi
  B_SD_WAN_IP=${sd_wan_cidr%/*}
  info "已选择本端 SD-WAN 接口: $B_SD_WAN_IF ($B_SD_WAN_IP)"

  # 根据本端 SD-WAN IP 最后一段生成 IPv6 ULA 地址
  local last_octet
  last_octet=$(awk -F. '{print $4}' <<<"$B_SD_WAN_IP")
  B_ETH1_IPV6_ULA="${IPV6_ULA_PREFIX}${last_octet}"

  local default_line
  default_line=$(ip route show default 0.0.0.0/0 | head -n1 || true)
  if [[ -z $default_line ]]; then
    die "未找到本端默认路由，无法配置SNAT"
  fi

  B_WAN_IF=$(awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$default_line")
  B_WAN_GW=$(awk '/via/ {for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<<"$default_line")
  if [[ -z $B_WAN_IF ]]; then
    die "无法确定默认出口网卡"
  fi
  local wan_cidr
  wan_cidr=$(ip -o -4 addr show dev "$B_WAN_IF" | awk '{print $4}' | head -n1)
  if [[ -z $wan_cidr ]]; then
    die "无法读取出口网卡($B_WAN_IF)的IPv4地址"
  fi
  B_WAN_IP=${wan_cidr%/*}

  # 检测本端 WAN 口是否有全局 IPv6 地址（排除 link-local fe80::）
  local wan_ipv6_cidr
  wan_ipv6_cidr=$(ip -o -6 addr show dev "$B_WAN_IF" scope global | awk '{print $4}' | head -n1 || true)
  if [[ -n $wan_ipv6_cidr ]]; then
    B_WAN_IPV6=${wan_ipv6_cidr%/*}
    HAS_WAN_IPV6=1
    info "检测到本端WAN口($B_WAN_IF)有全局IPv6地址: $B_WAN_IPV6"

    # 检测 IPv6 网关（用于修复多路径默认路由问题）
    local wan_ipv6_gw
    wan_ipv6_gw=$(ip -6 route show default dev "$B_WAN_IF" | awk '/via/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -n1 || true)
    if [[ -n $wan_ipv6_gw ]]; then
      B_WAN_IPV6_GW="$wan_ipv6_gw"
      info "检测到本端WAN口IPv6网关: $B_WAN_IPV6_GW"
    else
      B_WAN_IPV6_GW=""
      warn "未检测到本端WAN口IPv6网关，将在运行时动态检测"
    fi
  else
    HAS_WAN_IPV6=0
    B_WAN_IPV6_GW=""
    info "本端WAN口($B_WAN_IF)无全局IPv6地址，IPv6出口功能将不可用"
  fi
}

gather_remote_info() {
  A_HOSTNAME=$(ssh_remote "hostname -f 2>/dev/null || hostname")
  A_NIC_INFO=$(ssh_remote "ip -br addr show | while IFS= read -r line; do
    case \"\$line\" in
      lo[\ \	]*) continue ;;
      *) printf '%s\n' \"\$line\" ;;
    esac
  done")

  local remote_iface
  remote_iface=$(ssh_remote "ip -o -4 addr show | awk -v ip='$A_IP' '\$4 ~ (\"^\" ip \"/\") {print \$2; exit}'")
  if [[ -z $remote_iface ]]; then
    die "中国内地机器上找不到包含$A_IP的网卡"
  fi
  A_SD_WAN_IF=$remote_iface

  local addr_line
  addr_line=$(ssh_remote "ip -o -4 addr show dev '$A_SD_WAN_IF' | awk '\$4 ~ (\"^${A_IP}/\") {print \$4; exit}'" || true)
  if [[ -z $addr_line ]]; then
    warn "未能读取中国内地接口$A_SD_WAN_IF的CIDR，默认仅使用$A_IP"
  fi

  mapfile -t A_ADDR_LIST < <(ssh_remote "ip -o -4 addr show dev '$A_SD_WAN_IF' | awk '{print \$4}'")

  if [[ ${#A_ADDR_LIST[@]} -eq 0 ]]; then
    die "中国内地机器未检测到任何IPv4地址"
  fi

  if ssh_remote "[[ -d /sys/class/net/eth0 ]]" >/dev/null 2>&1; then
    local eth0_cidr
    eth0_cidr=$(ssh_remote "ip -o -4 addr show dev eth0 | awk '{print \$4}' | head -n1" || true)
    if [[ -n $eth0_cidr ]]; then
      A_ETH0_IP=${eth0_cidr%/*}
      A_ETH0_HAS_IPV4=1
      A_ETH0_GW=$(ssh_remote "ip -4 route show default dev eth0 | awk 'NR==1 {print \$3}'" || true)
      # 收集eth0上的所有IPv4地址（用于多IP策略路由）
      mapfile -t A_ETH0_IP_LIST < <(ssh_remote "ip -o -4 addr show dev eth0 | awk '{print \$4}'" | while read -r cidr; do echo "${cidr%/*}"; done)
      if [[ ${#A_ETH0_IP_LIST[@]} -gt 1 ]]; then
        info "检测到eth0有 ${#A_ETH0_IP_LIST[@]} 个IPv4地址: ${A_ETH0_IP_LIST[*]}"
      fi
    else
      A_ETH0_IP=""
      A_ETH0_GW=""
      A_ETH0_IP_LIST=()
      A_ETH0_IP6=$(ssh_remote "ip -o -6 addr show dev eth0 | awk '{print \$4}' | head -n1" || true)
    fi
  else
    A_ETH0_IP=""
    A_ETH0_GW=""
    A_ETH0_HAS_IPV4=0
    A_ETH0_IP_LIST=()
    A_ETH0_IP6=""
  fi

  if ssh_remote "[[ -d /sys/class/net/eth1 ]]" >/dev/null 2>&1; then
    local eth1_cidr
    eth1_cidr=$(ssh_remote "ip -o -4 addr show dev eth1 | awk '{print \$4}' | head -n1" || true)
    if [[ -n $eth1_cidr ]]; then
      A_ETH1_IP=${eth1_cidr%/*}
      A_ETH1_HAS_IPV4=1
      A_ETH1_GW=$(ssh_remote "ip -4 route show default dev eth1 | awk 'NR==1 {print \$3}'" || true)
    else
      A_ETH1_IP=""
      A_ETH1_GW=""
      A_ETH1_IP6=$(ssh_remote "ip -o -6 addr show dev eth1 | awk '{print \$4}' | head -n1" || true)
    fi
  else
    A_ETH1_IP=""
    A_ETH1_GW=""
    A_ETH1_HAS_IPV4=0
    A_ETH1_IP6=""
  fi

  # 根据内地端 SD-WAN IP 最后一段生成 IPv6 ULA 地址
  local a_last_octet
  a_last_octet=$(awk -F. '{print $4}' <<<"$A_IP")
  A_ETH1_IPV6_ULA="${IPV6_ULA_PREFIX}${a_last_octet}"

  # SD-WAN 是 L3 网络，IPv6 邻居发现无法穿透
  # 需要使用 SIT 隧道封装 IPv6 over IPv4
  info "将使用 SIT 隧道 ($SIT_TUNNEL_NAME) 传输 IPv6 流量"
}

enable_ip_forward() {
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  cat >"$SYSCTL_FILE" <<EOF
# 自动生成，确保本端机器能转发IPv4和IPv6
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
}

build_nft_elements() {
  local -a unique_list=()
  declare -A seen=()
  for cidr in "${A_ADDR_LIST[@]}"; do
    local ip=${cidr%/*}
    [[ -z $ip ]] && continue
    if [[ -z ${seen[$ip]+x} ]]; then
      seen[$ip]=1
      unique_list+=("$ip")
    fi
  done
  if [[ ${#unique_list[@]} -eq 0 ]]; then
    unique_list+=("$A_IP")
  fi
  local joined=""
  for ip in "${unique_list[@]}"; do
    if [[ -z $joined ]]; then
      joined="$ip"
    else
      joined="$joined, $ip"
    fi
  done
  echo "$joined"
}

deploy_nft() {
  ensure_package "nftables" "nft"
  enable_ip_forward

  local elements
  elements=$(build_nft_elements)
  mkdir -p "$(dirname "$NFT_SCRIPT_PATH")"

  # 根据是否有 WAN IPv6 生成不同的脚本
  if [[ $HAS_WAN_IPV6 -eq 1 ]]; then
    # 有 WAN IPv6：配置 SIT 隧道 + IPv4 SNAT + IPv6 NAT66
    info "生成 SIT 隧道 + IPv4 SNAT + IPv6 NAT66 配置..."
cat >"$NFT_SCRIPT_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set +o braceexpand
PATH=/sbin:/usr/sbin:/bin:/usr/bin

# ========== SIT 隧道配置（IPv6 over IPv4） ==========
# SD-WAN 是 L3 网络，IPv6 邻居发现无法穿透，需要 SIT 隧道
ip tunnel del $SIT_TUNNEL_NAME 2>/dev/null || true
ip tunnel add $SIT_TUNNEL_NAME mode sit remote $A_IP local $B_SD_WAN_IP ttl 255
ip link set $SIT_TUNNEL_NAME up

# 配置隧道的 IPv6 ULA 地址
ip -6 addr add ${B_ETH1_IPV6_ULA}/64 dev $SIT_TUNNEL_NAME 2>/dev/null || true

# ========== IPv4 SNAT 规则 ==========
nft delete table ip ab_snat >/dev/null 2>&1 || true
nft -f - <<'NFT'
table ip ab_snat {
  set a_sources {
    type ipv4_addr
    elements = { $elements }
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$B_SD_WAN_IF"
    oifname "$B_WAN_IF"
    ip saddr @a_sources masquerade
  }
}
NFT

# ========== IPv6 NAT66 规则（通过 SIT 隧道） ==========
nft delete table ip6 ab_snat6 >/dev/null 2>&1 || true
nft -f - <<'NFT6'
table ip6 ab_snat6 {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$SIT_TUNNEL_NAME" oifname "$B_WAN_IF" masquerade
  }
}
NFT6

# ========== 修复 IPv6 默认路由（防止 ECMP 多路径导致间歇性失败） ==========
# 系统可能通过 RA 学到多条 nexthop（含非 WAN 接口），导致 IPv6 流量随机走错路径
IPV6_GW="${B_WAN_IPV6_GW}"
if [[ -z "\$IPV6_GW" ]]; then
  # 运行时动态检测 WAN 口的 IPv6 网关
  IPV6_GW=\$(ip -6 route show default dev $B_WAN_IF 2>/dev/null | awk '/via/{for(i=1;i<=NF;i++) if(\$i=="via"){print \$(i+1); exit}}' | head -n1 || true)
fi
if [[ -n "\$IPV6_GW" ]]; then
  # 检查当前默认路由是否为多路径（含多个 nexthop）
  nhcount=\$(ip -6 route show default 2>/dev/null | grep -c 'nexthop' || echo 0)
  if [[ "\$nhcount" -gt 1 ]]; then
    echo "检测到 IPv6 多路径默认路由(\${nhcount}条nexthop)，修复为仅走 $B_WAN_IF..."
    ip -6 route del default 2>/dev/null || true
    ip -6 route add default via "\$IPV6_GW" dev $B_WAN_IF 2>/dev/null || true
  fi
fi
EOF
  else
    # 无 WAN IPv6，仅配置 IPv4 SNAT
    info "本端无 IPv6 出口，仅配置 IPv4 SNAT..."
cat >"$NFT_SCRIPT_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set +o braceexpand
PATH=/sbin:/usr/sbin:/bin:/usr/bin

# IPv4 SNAT 规则
nft delete table ip ab_snat >/dev/null 2>&1 || true
nft -f - <<'NFT'
table ip ab_snat {
  set a_sources {
    type ipv4_addr
    elements = { $elements }
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$B_SD_WAN_IF"
    oifname "$B_WAN_IF"
    ip saddr @a_sources masquerade
  }
}
NFT
EOF
  fi

  chmod 700 "$NFT_SCRIPT_PATH"

  cat >"$NFT_SERVICE_PATH" <<EOF
[Unit]
Description=AB SNAT 规则加载 (IPv4 + IPv6)
After=network-online.target network.target NetworkManager.service systemd-networkd.service networking.service
Wants=network-online.target
Requires=network-online.target
PartOf=systemd-networkd.service NetworkManager.service networking.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ab-nft-restore.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target network-online.target
EOF

  systemctl daemon-reload
  bash "$NFT_SCRIPT_PATH"
  systemctl enable --now ab-nft.service >/dev/null
}

deploy_remote_routes() {
  info "在中国内地机器创建策略路由脚本..."
  local table_name="ab_eth0"
  local table_id=100
  local eth1_table_name="ab_eth1"
  local eth1_table_id=110
  local sdwan_table_name="ab_sdwan"
  local sdwan_table_id=90
  local sdwan_rule_priority=2000
  local local_net_rule_priority=1900
  local eth0_rule_priority=1000
  local eth1_rule_priority=1100  # 留出空间给eth0多IP场景（eth0用1000-1099）
  local ssh_whitelist_priority=500

  # 获取本端机器的公网IP作为SSH管理白名单
  local ssh_mgmt_ip="$B_WAN_IP"

  local remote_script
  remote_script=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
PATH=/sbin:/usr/sbin:/bin:/usr/bin

SDWAN_TABLE_ID=$sdwan_table_id
SDWAN_TABLE_NAME="$sdwan_table_name"
SDWAN_RULE_PRIORITY=$sdwan_rule_priority
LOCAL_NET_RULE_PRIORITY=$local_net_rule_priority

ETH0_TABLE_ID=$table_id
ETH0_TABLE_NAME="$table_name"
ETH0_RULE_PRIORITY=$eth0_rule_priority

ETH1_TABLE_ID=$eth1_table_id
ETH1_TABLE_NAME="$eth1_table_name"
ETH1_RULE_PRIORITY=$eth1_rule_priority

SSH_WHITELIST_PRIORITY=$ssh_whitelist_priority
SSH_MGMT_IP="$ssh_mgmt_ip"

ETH_LINK_DEV="$A_SD_WAN_IF"
ETH_LINK_GW="$B_SD_WAN_IP"
ETH0_DEV="eth0"
ETH0_GW="$A_ETH0_GW"
ETH0_SRC="$A_ETH0_IP"
ETH0_SRC_LIST="${A_ETH0_IP_LIST[*]}"  # 所有eth0 IP地址（空格分隔）
ETH0_HAS_IPV4="$A_ETH0_HAS_IPV4"
ETH1_DEV="eth1"
ETH1_GW="$A_ETH1_GW"
ETH1_SRC="$A_ETH1_IP"
ETH1_HAS_IPV4="$A_ETH1_HAS_IPV4"

# IPv6 配置（使用 SIT 隧道封装 IPv6 over IPv4）
IPV6_LOCAL_ULA="${A_ETH1_IPV6_ULA}/64"
IPV6_GW_ULA="$B_ETH1_IPV6_ULA"
HAS_WAN_IPV6="$HAS_WAN_IPV6"
SIT_TUNNEL_NAME="$SIT_TUNNEL_NAME"
SIT_REMOTE_IP="$B_SD_WAN_IP"
SIT_LOCAL_IP="$A_IP"

ensure_table_entry() {
  local table_id=\$1
  local table_name=\$2
  local table_file="/etc/iproute2/rt_tables"
  mkdir -p "/etc/iproute2"
  touch "\$table_file"
  if ! grep -qE "^\\s*\${table_id}\\s+\${table_name}\\s*\$" "\$table_file"; then
    echo "\${table_id} \${table_name}" >>"\$table_file"
  fi
}

cleanup_src_rules() {
  local src=\$1
  local table=\$2
  ip rule show | awk -v table="\$table" -v src="\$src" '\$0 ~ ("from " src "/32") && \$0 ~ ("lookup " table) {gsub(/:$/,"",\$1); print \$1}' | while read -r prio; do
    [[ -z "\$prio" ]] && continue
    ip rule del priority "\$prio" || true
  done
}

cleanup_table_rules() {
  local table=\$1
  ip rule show | awk -v table="\$table" '\$0 ~ ("lookup " table) {gsub(/:$/,"",\$1); print \$1}' | while read -r prio; do
    [[ -z "\$prio" ]] && continue
    ip rule del priority "\$prio" || true
  done
}

cleanup_dst_rules() {
  local dst=\$1
  ip rule show | awk -v dst="\$dst" '\$0 ~ ("to " dst "/32") {gsub(/:$/,"",\$1); print \$1}' | while read -r prio; do
    [[ -z "\$prio" ]] && continue
    ip rule del priority "\$prio" || true
  done
}

dev_exists() {
  local dev=\$1
  [[ -n "\$dev" ]] && [[ -e "/sys/class/net/\$dev" ]]
}

add_local_net_rules() {
  # 确保本机已连接网段继续走main表，避免被默认sdwan规则覆盖
  ip -o -4 addr show scope global | awk '{print \$4}' | while read -r cidr; do
    [[ -z "\$cidr" ]] && continue
    ip rule add priority "\$LOCAL_NET_RULE_PRIORITY" to "\$cidr" lookup main 2>/dev/null || true
  done
}

setup_ssh_whitelist() {
  # 为SSH管理IP添加最高优先级规则，确保管理流量始终走eth0原网关
  if [[ -z "\$SSH_MGMT_IP" ]]; then
    echo "未配置SSH管理IP白名单，跳过"
    return 0
  fi
  if [[ "\$ETH0_HAS_IPV4" != "1" ]] || [[ -z "\$ETH0_GW" ]]; then
    echo "eth0无IPv4网关，无法配置SSH白名单"
    return 0
  fi
  echo "配置SSH管理IP白名单: \$SSH_MGMT_IP -> eth0原网关"
  cleanup_dst_rules "\$SSH_MGMT_IP"
  ip rule del priority "\$SSH_WHITELIST_PRIORITY" 2>/dev/null || true
  ip rule add to "\$SSH_MGMT_IP/32" table "\$ETH0_TABLE_NAME" priority "\$SSH_WHITELIST_PRIORITY"
}

setup_eth0_policy() {
  if ! dev_exists "\$ETH0_DEV"; then
    echo "eth0接口不存在，跳过eth0策略路由"
    return 0
  fi
  if [[ "\$ETH0_HAS_IPV4" != "1" ]]; then
    echo "eth0未检测到IPv4，跳过eth0策略路由"
    return 0
  fi
  if [[ -z "\$ETH0_GW" || -z "\$ETH0_SRC" ]]; then
    echo "eth0缺少IPv4网关或地址，跳过eth0策略路由"
    return 0
  fi
  ensure_table_entry "\$ETH0_TABLE_ID" "\$ETH0_TABLE_NAME"
  # 使用 onlink 参数，支持云服务器网关不在直连网段的情况
  ip route replace table "\$ETH0_TABLE_NAME" default via "\$ETH0_GW" dev "\$ETH0_DEV" onlink

  # 为eth0上的所有IP地址配置策略路由（支持多IP场景）
  local ip_list=(\$ETH0_SRC_LIST)
  if [[ \${#ip_list[@]} -eq 0 ]]; then
    ip_list=("\$ETH0_SRC")
  fi

  local rule_prio="\$ETH0_RULE_PRIORITY"
  for src_ip in "\${ip_list[@]}"; do
    [[ -z "\$src_ip" ]] && continue
    cleanup_src_rules "\$src_ip" "\$ETH0_TABLE_NAME"
    # 删除该优先级已有的规则（如果有）
    ip rule del priority "\$rule_prio" 2>/dev/null || true
    ip rule add from "\$src_ip/32" table "\$ETH0_TABLE_NAME" priority "\$rule_prio"
    echo "为eth0 IP \$src_ip 配置策略路由 (优先级 \$rule_prio)"
    # 每个IP使用递增的优先级，避免冲突
    rule_prio=\$((rule_prio + 1))
  done
}

setup_eth1_policy() {
  if ! dev_exists "\$ETH1_DEV"; then
    echo "eth1接口不存在，跳过eth1策略路由"
    return 0
  fi
  if [[ "\$ETH1_HAS_IPV4" != "1" ]]; then
    echo "eth1未检测到IPv4，跳过eth1策略路由"
    return 0
  fi
  if [[ -z "\$ETH1_SRC" ]]; then
    echo "eth1缺少IPv4地址，跳过eth1策略路由"
    return 0
  fi
    ensure_table_entry "\$ETH1_TABLE_ID" "\$ETH1_TABLE_NAME"
    # 即便没有网关，也复制直连路由，保证源进源出
    ip route flush table "\$ETH1_TABLE_NAME" >/dev/null 2>&1 || true
    ip -4 route show dev "\$ETH1_DEV" scope link 2>/dev/null | while read -r r; do
      [[ -z "\$r" ]] && continue
      ip route replace table "\$ETH1_TABLE_NAME" \$r 2>/dev/null || true
    done
    if [[ -n "\$ETH1_GW" ]]; then
      # 使用 onlink 参数，支持云服务器网关不在直连网段的情况
      ip route replace table "\$ETH1_TABLE_NAME" default via "\$ETH1_GW" dev "\$ETH1_DEV" onlink 2>/dev/null || true
    fi
    cleanup_src_rules "\$ETH1_SRC" "\$ETH1_TABLE_NAME"
    ip rule del priority "\$ETH1_RULE_PRIORITY" 2>/dev/null || true
    ip rule add from "\$ETH1_SRC/32" table "\$ETH1_TABLE_NAME" priority "\$ETH1_RULE_PRIORITY"
}

setup_sdwan_policy() {
  if ! dev_exists "\$ETH_LINK_DEV"; then
    echo "SDWAN接口(\$ETH_LINK_DEV)不存在，跳过sdwan策略"
    return 0
  fi
  ensure_table_entry "\$SDWAN_TABLE_ID" "\$SDWAN_TABLE_NAME"
  # 使用 onlink 参数，支持网关不在直连网段的情况
  ip route replace table "\$SDWAN_TABLE_NAME" default via "\$ETH_LINK_GW" dev "\$ETH_LINK_DEV" onlink 2>/dev/null || true
  cleanup_table_rules "\$SDWAN_TABLE_NAME"
  add_local_net_rules
  ip rule del priority "\$SDWAN_RULE_PRIORITY" 2>/dev/null || true
  ip rule add priority "\$SDWAN_RULE_PRIORITY" lookup "\$SDWAN_TABLE_NAME"
}

setup_ipv6_route() {
  # 配置 IPv6 路由，让 IPv6 流量通过香港端出口
  # SD-WAN 是 L3 网络，IPv6 邻居发现无法穿透，使用 SIT 隧道封装 IPv6 over IPv4
  if [[ "\$HAS_WAN_IPV6" != "1" ]]; then
    echo "香港端无 IPv6 出口，跳过 IPv6 路由配置"
    return 0
  fi

  if [[ -z "\$IPV6_LOCAL_ULA" || -z "\$IPV6_GW_ULA" ]]; then
    echo "IPv6 ULA 配置为空，跳过 IPv6 路由配置"
    return 0
  fi

  echo "创建 SIT 隧道: \$SIT_TUNNEL_NAME (local=\$SIT_LOCAL_IP, remote=\$SIT_REMOTE_IP)"
  # 删除已有的 SIT 隧道（如果存在）
  ip tunnel del "\$SIT_TUNNEL_NAME" 2>/dev/null || true
  # 创建 SIT 隧道（IPv6 over IPv4）
  ip tunnel add "\$SIT_TUNNEL_NAME" mode sit remote "\$SIT_REMOTE_IP" local "\$SIT_LOCAL_IP" ttl 255
  ip link set "\$SIT_TUNNEL_NAME" up

  echo "配置 SIT 隧道 IPv6 地址: \$IPV6_LOCAL_ULA"
  ip -6 addr add "\$IPV6_LOCAL_ULA" dev "\$SIT_TUNNEL_NAME" 2>/dev/null || true

  echo "配置 IPv6 默认路由: via \$IPV6_GW_ULA dev \$SIT_TUNNEL_NAME"
  # 删除已有的默认路由（避免冲突）
  ip -6 route del default 2>/dev/null || true
  # 添加 IPv6 默认路由通过 SIT 隧道
  ip -6 route replace default via "\$IPV6_GW_ULA" dev "\$SIT_TUNNEL_NAME" 2>/dev/null || true
}

rollback_all() {
  echo "检测到异常，回滚所有策略路由配置..."
  ip rule del priority "\$SDWAN_RULE_PRIORITY" 2>/dev/null || true
  while ip rule del priority "\$LOCAL_NET_RULE_PRIORITY" 2>/dev/null; do :; done
  # 清理所有可能的eth0 IP规则（优先级1000-1009）
  for prio in \$(seq "\$ETH0_RULE_PRIORITY" \$((ETH0_RULE_PRIORITY + 10))); do
    ip rule del priority "\$prio" 2>/dev/null || true
  done
  ip rule del priority "\$ETH1_RULE_PRIORITY" 2>/dev/null || true
  ip rule del priority "\$SSH_WHITELIST_PRIORITY" 2>/dev/null || true
  # 回滚 IPv6 路由和 SIT 隧道
  ip -6 route del default 2>/dev/null || true
  ip tunnel del "\$SIT_TUNNEL_NAME" 2>/dev/null || true
  echo "回滚完成"
}

verify_connectivity() {
  # 验证配置后是否还能连通外网
  local test_ip="8.8.8.8"
  if ! ping -c 1 -W 3 "\$test_ip" >/dev/null 2>&1; then
    echo "警告: 配置后无法ping通 \$test_ip"
    return 1
  fi
  return 0
}

# 执行顺序调整：先配置eth0/eth1保底路由，再配置SSH白名单，最后配置SD-WAN默认路由
setup_eth0_policy
setup_eth1_policy
setup_ssh_whitelist
setup_sdwan_policy

# 配置 IPv6 路由（让 IPv6 流量通过香港端出口）
setup_ipv6_route

# 验证连通性，失败则回滚
if ! verify_connectivity; then
  rollback_all
  exit 1
fi
EOF
)

  ssh_remote "cat <<'__AB__' > $REMOTE_ROUTE_SCRIPT
$remote_script
__AB__"
  ssh_remote "chmod 700 $REMOTE_ROUTE_SCRIPT"

  local service_unit
  service_unit=$(cat <<EOF
[Unit]
Description=AB 默认路由&策略路由持久化
After=network-online.target network.target NetworkManager.service systemd-networkd.service networking.service
Wants=network-online.target
Requires=network-online.target
PartOf=systemd-networkd.service NetworkManager.service networking.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ab-route-setup.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target network-online.target
EOF
)

  ssh_remote "cat <<'__ABUNIT__' > $REMOTE_ROUTE_SERVICE
$service_unit
__ABUNIT__"

  ssh_remote "systemctl daemon-reload"
  ssh_remote "systemctl enable $(basename "$REMOTE_ROUTE_SERVICE")"
  # 重启服务以应用新配置（enable --now 对已 active 的服务不会重新执行）
  ssh_remote "systemctl restart $(basename "$REMOTE_ROUTE_SERVICE")"
}

configure_remote_dns() {
  info "在中国内地机器配置DNS（主: $B_SD_WAN_IP / 备: 1.1.1.1）并持久化..."
  local dns_script
  dns_script=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DNS_FILE="/etc/resolv.conf"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_FILE="${DNS_FILE}.halocloud.${STAMP}.bak"
DNS_SERVICE_SCRIPT="/usr/local/sbin/ab-dns-setup.sh"
DNS_SERVICE_FILE="/etc/systemd/system/ab-dns-setup.service"

backup_existing() {
  if [[ -L "$DNS_FILE" ]]; then
    cp -L "$DNS_FILE" "$BACKUP_FILE" 2>/dev/null || cat "$DNS_FILE" >"$BACKUP_FILE"
  elif [[ -f "$DNS_FILE" ]]; then
    cp "$DNS_FILE" "$BACKUP_FILE" 2>/dev/null || cat "$DNS_FILE" >"$BACKUP_FILE"
  fi
}

write_resolv_conf() {
  # 先解除不可变属性（如果有）
  chattr -i "$DNS_FILE" 2>/dev/null || true
  # 删除符号链接（如果是）
  if [[ -L "$DNS_FILE" ]]; then
    rm -f "$DNS_FILE"
  fi
  cat >"$DNS_FILE" <<DNSCONF
# Managed by HaloCloud组网脚本 at $STAMP
nameserver __DNS1__
nameserver __DNS2__
options timeout:2 attempts:2
DNSCONF
  chmod 644 "$DNS_FILE"
  # 设置不可变属性，防止被其他服务覆盖
  chattr +i "$DNS_FILE" 2>/dev/null || true
}

configure_systemd_resolved() {
  # 配置 systemd-resolved（如果存在）
  local resolved_conf="/etc/systemd/resolved.conf"
  if [[ -f "$resolved_conf" ]]; then
    # 备份原文件
    cp "$resolved_conf" "${resolved_conf}.halocloud.bak" 2>/dev/null || true
    # 设置DNS
    if grep -q '^\[Resolve\]' "$resolved_conf"; then
      sed -i '/^DNS=/d; /^FallbackDNS=/d; /^DNSStubListener=/d' "$resolved_conf"
      sed -i '/^\[Resolve\]/a DNS=__DNS1__ __DNS2__\nFallbackDNS=8.8.8.8 8.8.4.4\nDNSStubListener=no' "$resolved_conf"
    else
      cat >>"$resolved_conf" <<RESOLVED
[Resolve]
DNS=__DNS1__ __DNS2__
FallbackDNS=8.8.8.8 8.8.4.4
DNSStubListener=no
RESOLVED
    fi
    # 重启 systemd-resolved
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
}

configure_networkmanager() {
  # 配置 NetworkManager（如果存在）
  local nm_conf_dir="/etc/NetworkManager/conf.d"
  if [[ -d "$nm_conf_dir" ]] || command -v nmcli >/dev/null 2>&1; then
    mkdir -p "$nm_conf_dir"
    cat >"${nm_conf_dir}/99-halocloud-dns.conf" <<NMCONF
[main]
dns=none

[global-dns-domain-*]
servers=__DNS1__,__DNS2__
NMCONF
    # 重新加载 NetworkManager
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
  fi
}

create_dns_service() {
  # 创建 DNS 设置脚本
  cat >"$DNS_SERVICE_SCRIPT" <<'DNSSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DNS_FILE="/etc/resolv.conf"
chattr -i "$DNS_FILE" 2>/dev/null || true
[[ -L "$DNS_FILE" ]] && rm -f "$DNS_FILE"
cat >"$DNS_FILE" <<DNSCONF
# Managed by HaloCloud组网脚本
nameserver __DNS1__
nameserver __DNS2__
options timeout:2 attempts:2
DNSCONF
chmod 644 "$DNS_FILE"
chattr +i "$DNS_FILE" 2>/dev/null || true
DNSSCRIPT
  chmod 700 "$DNS_SERVICE_SCRIPT"

  # 创建 systemd 服务
  cat >"$DNS_SERVICE_FILE" <<SVCUNIT
[Unit]
Description=HaloCloud DNS配置持久化
After=network-online.target network.target NetworkManager.service systemd-networkd.service systemd-resolved.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ab-dns-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCUNIT

  systemctl daemon-reload
  systemctl enable ab-dns-setup.service
}

# 执行配置
backup_existing
configure_systemd_resolved
configure_networkmanager
write_resolv_conf
create_dns_service
echo "DNS配置完成并已持久化"
EOF
)

  # 将占位符替换为实际 DNS 地址（主: 香港机器, 备: Cloudflare）
  dns_script="${dns_script//__DNS1__/$B_SD_WAN_IP}"
  dns_script="${dns_script//__DNS2__/1.1.1.1}"

  ssh_remote "cat <<'__DNS__' > /tmp/ab-set-dns.sh
$dns_script
__DNS__"
  ssh_remote "chmod 700 /tmp/ab-set-dns.sh && /tmp/ab-set-dns.sh && rm -f /tmp/ab-set-dns.sh"
}

configure_remote_ipv4_prefer() {
  info "在中国内地机器设置IPv4优先..."
  ssh_remote "GAI_CONF=/etc/gai.conf; touch \"\$GAI_CONF\"; \
if grep -q '^#precedence ::ffff:0:0/96  100' \"\$GAI_CONF\"; then \
  sed -i 's/^#precedence ::ffff:0:0\\/96  *100/precedence ::ffff:0:0\\/96  100/' \"\$GAI_CONF\"; \
elif ! grep -q '^precedence ::ffff:0:0/96  100' \"\$GAI_CONF\"; then \
  echo 'precedence ::ffff:0:0/96  100' >>\"\$GAI_CONF\"; \
fi; \
chmod 644 \"\$GAI_CONF\""
}

print_summary() {
  local eth0_ip_display
  local eth0_gw_display
  local eth0_note=""
  local eth0_listen_hint
  local eth0_ip6_display="${A_ETH0_IP6:-无IPv6}"
  local eth1_ip_display
  local eth1_gw_display
  local eth1_note=""
  local eth1_ip6_display="${A_ETH1_IP6:-无IPv6}"
  if [[ $A_ETH0_HAS_IPV4 -eq 1 ]]; then
    # 显示所有eth0 IP地址
    if [[ ${#A_ETH0_IP_LIST[@]} -gt 1 ]]; then
      eth0_ip_display="${A_ETH0_IP_LIST[*]} (共${#A_ETH0_IP_LIST[@]}个)"
      eth0_listen_hint="eth0的任一IPv4(${A_ETH0_IP_LIST[*]})或IPv6(${eth0_ip6_display})"
    else
      eth0_ip_display=${A_ETH0_IP:-无}
      eth0_listen_hint="eth0的IPv4(${A_ETH0_IP:-未知})或IPv6(${eth0_ip6_display})"
    fi
    eth0_gw_display=${A_ETH0_GW:-无}
  else
    eth0_ip_display="无(IPv6: ${eth0_ip6_display})"
    eth0_gw_display="无"
    eth0_note="(eth0仅IPv6，策略路由已跳过)"
    eth0_listen_hint="eth0的IPv6地址(${eth0_ip6_display})"
  fi
  if [[ $A_ETH1_HAS_IPV4 -eq 1 ]]; then
    eth1_ip_display=${A_ETH1_IP:-无}
    eth1_gw_display=${A_ETH1_GW:-无}
  else
    eth1_ip_display="无(IPv6: ${eth1_ip6_display})"
    eth1_gw_display="无"
    eth1_note="(eth1仅IPv6，策略路由已跳过)"
  fi

  info "=== 本端机器网卡信息 ==="
  printf '%s\n' "$LOCAL_NIC_INFO"
  info "=== 中国内地机器网卡信息 ==="
  printf '%s\n' "$A_NIC_INFO"

  # IPv6 模式描述
  local ipv6_mode_desc
  local ipv6_tunnel_info=""
  if [[ $HAS_WAN_IPV6 -eq 1 ]]; then
    ipv6_mode_desc="SIT隧道 + NAT66"
    ipv6_tunnel_info="
  SIT隧道: $SIT_TUNNEL_NAME ($B_SD_WAN_IP <-> $A_IP)"
  else
    ipv6_mode_desc="无IPv6出口"
  fi

  cat <<EOF

-------------------------
本端机器 ($LOCAL_HOSTNAME):
  SD-WAN接口: $B_SD_WAN_IF ($B_SD_WAN_IP)
  WAN接口: $B_WAN_IF ($B_WAN_IP via $B_WAN_GW)
  WAN IPv6: ${B_WAN_IPV6:-无}
  IPv6模式: $ipv6_mode_desc${ipv6_tunnel_info}
  IPv6 ULA: ${B_ETH1_IPV6_ULA}/64
  SNAT脚本: $NFT_SCRIPT_PATH
  SNAT服务: $(basename "$NFT_SERVICE_PATH")
  sysctl文件: $SYSCTL_FILE (含IPv6转发)

中国内地机器 ($A_HOSTNAME):
  SSH端口: $A_SSH_PORT
  中国内地接入接口: $A_SD_WAN_IF ($A_IP)
  eth0源IP: $eth0_ip_display | eth0网关: $eth0_gw_display $eth0_note
  eth1源IP: $eth1_ip_display | eth1网关: $eth1_gw_display $eth1_note
  IPv6 ULA: ${A_ETH1_IPV6_ULA}/64 (默认路由指向 $B_ETH1_IPV6_ULA)
  SSH管理白名单: $B_WAN_IP (优先级500，确保管理流量走eth0原网关)
  路由脚本: $REMOTE_ROUTE_SCRIPT
  路由服务: $(basename "$REMOTE_ROUTE_SERVICE")
  DNS: $B_SD_WAN_IP (主) / 1.1.1.1 (备)
  DNS脚本: /usr/local/sbin/ab-dns-setup.sh
  DNS服务: ab-dns-setup.service (重启后自动恢复DNS)
  IPv4优先: /etc/gai.conf (precedence ::ffff:0:0/96 100)
-------------------------

操作完成，如需查看状态:
  - 在本端机器执行: systemctl status ab-nft.service
  - 在中国内地机器执行: systemctl status ab-route-setup.service

附加提示:
  - 若希望UDP会话沿中国内地eth0原IP回源，请让业务程序仅监听中国内地eth0地址（当前探测为: $eth0_listen_hint），勿使用0.0.0.0/::通配监听，以确保响应始终匹配策略路由。
  - 自动apt更新服务已禁用（防止干扰网络配置），如需恢复请在中国内地机器执行:
    cat $AUTO_UPGRADE_STATE_FILE  # 查看原始状态
    rm -f $AUTO_UPGRADE_STATE_FILE && systemctl enable --now apt-daily.timer apt-daily-upgrade.timer  # 恢复

EOF

  # 仅在有 IPv6 出口时显示测试命令
  if [[ $HAS_WAN_IPV6 -eq 1 ]]; then
    cat <<EOF

IPv6 出口测试（在中国内地机器执行）:
  ip tunnel show                          # 查看 SIT 隧道状态
  ping -6 $B_ETH1_IPV6_ULA                # 测试到香港端的 IPv6 连通性
  ping -6 2001:4860:4860::8888            # 测试 IPv6 出网（Google DNS）
  curl -6 ifconfig.co                     # 查看 IPv6 出口地址
  ip -6 route show                        # 查看 IPv6 路由表
EOF
  fi
}

main() {
  require_root
  detect_pkg_manager
  ensure_package "sshpass" "sshpass"
  ensure_package "nftables" "nft"
  prompt_inputs
  check_sdwan_connectivity
  test_remote
  gather_local_info
  gather_remote_info
  deploy_nft
  disable_remote_auto_upgrade
  deploy_remote_routes
  configure_remote_dns
  configure_remote_ipv4_prefer
  print_summary
}

main "$@"
