#!/usr/bin/env python3
# ============================================================================
# setup-pbr.py — 多网卡 / 多出口 VM 一键策略路由配置脚本
#
# 功能：
#   1. 读取 cloud-init 生成的 netplan 配置（50-cloud-init.yaml）
#   2. 自动提取所有接口的 IPv4/IPv6 地址、子网、网关信息
#   3. 生成带 metric 的路由配置（60-ethernet.yaml）
#   4. 生成策略路由 PBR 配置（90-pbr.yaml）
#   5. 通过 netplan try 安全应用
#
# 用法：
#   sudo python3 setup-pbr.py                          # 使用默认配置路径
#   sudo python3 setup-pbr.py /path/to/netplan.yaml    # 指定配置文件
#   sudo python3 setup-pbr.py --dry-run                # 仅预览，不写入
#
# 依赖：python3, python3-yaml (PyYAML)
# 适用：Debian 12 / Debian 13 (Netplan)
# ============================================================================

from __future__ import annotations

import argparse
import copy
import ipaddress
import os
import shutil
import subprocess
import re
import sys
from datetime import datetime
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ── 依赖检查 ──────────────────────────────────────────────────────────────────

try:
    import yaml
except ImportError:
    print("\033[0;31m[ERR]\033[0m  未找到 PyYAML，请先安装: apt install python3-yaml")
    sys.exit(1)

# ── 颜色输出 ──────────────────────────────────────────────────────────────────

class Log:
    RED    = "\033[0;31m"
    GREEN  = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN   = "\033[0;36m"
    NC     = "\033[0m"

    @staticmethod
    def info(msg: str)  -> None: print(f"{Log.CYAN}[INFO]{Log.NC}  {msg}")
    @staticmethod
    def ok(msg: str)    -> None: print(f"{Log.GREEN}[ OK ]{Log.NC}  {msg}")
    @staticmethod
    def warn(msg: str)  -> None: print(f"{Log.YELLOW}[WARN]{Log.NC}  {msg}")
    @staticmethod
    def err(msg: str)   -> None: print(f"{Log.RED}[ERR]{Log.NC}   {msg}", file=sys.stderr)

# ── 数据结构 ──────────────────────────────────────────────────────────────────

@dataclass
class InterfaceInfo:
    name: str
    ipv4_subnets:  list[str] = field(default_factory=list)
    ipv4_gateways: list[str] = field(default_factory=list)
    ipv6_subnets:  list[str] = field(default_factory=list)
    ipv6_gateways: list[str] = field(default_factory=list)

    @property
    def has_default_route(self) -> bool:
        return bool(self.ipv4_gateways or self.ipv6_gateways)

    def summary(self) -> str:
        gws  = ", ".join(self.ipv4_gateways + self.ipv6_gateways)
        nets = ", ".join(self.ipv4_subnets  + self.ipv6_subnets)
        return f"{self.name}: 网关=[{gws}]  子网=[{nets}]"

# ── 解析 ──────────────────────────────────────────────────────────────────────

def parse_netplan(path: Path) -> dict[str, Any]:
    """读取并返回 netplan YAML 配置"""
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        Log.err(f"YAML 解析失败: {e}")
        sys.exit(1)
    except OSError as e:
        Log.err(f"无法读取文件 {path}: {e}")
        sys.exit(1)


def extract_interfaces(config: dict[str, Any]) -> list[InterfaceInfo]:
    """从 netplan 配置中提取所有以太网接口信息"""
    ethernets = config.get("network", {}).get("ethernets", {})
    if not ethernets:
        Log.err("配置文件中未找到任何以太网接口 (network.ethernets)")
        sys.exit(1)

    interfaces: list[InterfaceInfo] = []

    for iface_name, iface_cfg in ethernets.items():
        info = InterfaceInfo(name=iface_name)

        # 提取地址 → 计算子网
        for addr_entry in iface_cfg.get("addresses", []):
            addr_str = (
                addr_entry
                if isinstance(addr_entry, str)
                else addr_entry.get("address", "")
            )
            if not addr_str:
                continue
            try:
                net = ipaddress.ip_interface(addr_str)
                target = info.ipv4_subnets if net.version == 4 else info.ipv6_subnets
                target.append(str(net.network))
            except ValueError:
                Log.warn(f"  跳过无法解析的地址: {addr_str}")

        # 提取网关（从 routes 字段）
        for route in iface_cfg.get("routes", []):
            to  = str(route.get("to", ""))
            via = str(route.get("via", ""))
            if not via:
                continue
            if to in ("default", "0.0.0.0/0"):
                info.ipv4_gateways.append(via)
            elif to == "::/0":
                info.ipv6_gateways.append(via)

        # 兼容旧式 gateway4 / gateway6（已弃用但仍可能存在）
        for attr, lst in [
            ("gateway4", info.ipv4_gateways),
            ("gateway6", info.ipv6_gateways),
        ]:
            gw = iface_cfg.get(attr)
            if gw and str(gw) not in lst:
                lst.append(str(gw))

        interfaces.append(info)

    return interfaces

# ── Metric 分配 ───────────────────────────────────────────────────────────────

def assign_metrics(count: int) -> list[int]:
    """
    为 n 个接口分配 metric 值。
    排在后面的接口优先级越高（metric 越小）。
    两个接口时：第一个 50，最后一个 25。
    """
    if count == 1:
        return [100]
    return [50 - (50 - 25) * i // (count - 1) for i in range(count)]

# ── 生成配置 ──────────────────────────────────────────────────────────────────

def generate_ethernet_config(
    original: dict[str, Any],
    routed: list[InterfaceInfo],
    metrics: list[int],
) -> dict[str, Any]:
    """深拷贝原始配置，为所有默认路由注入 metric"""
    config   = copy.deepcopy(original)
    name_idx = {iface.name: i for i, iface in enumerate(routed)}

    for iface_name, iface_cfg in config.get("network", {}).get("ethernets", {}).items():
        if iface_name not in name_idx:
            continue
        for route in iface_cfg.get("routes", []):
            if str(route.get("to", "")) in ("default", "0.0.0.0/0", "::/0"):
                route["metric"] = metrics[name_idx[iface_name]]

    return config


def generate_pbr_config(routed: list[InterfaceInfo]) -> dict[str, Any]:
    """为每个接口生成独立路由表和源地址策略路由"""
    pbr_ethernets: dict[str, Any] = {}
    table_id = 10

    for iface in routed:
        routes: list[dict[str, Any]] = []
        policy: list[dict[str, Any]] = []

        # IPv4
        for gw in iface.ipv4_gateways:
            routes.append({"to": "default", "via": gw, "table": table_id})
        for subnet in iface.ipv4_subnets:
            policy.append({"from": subnet, "table": table_id})

        # IPv6
        for gw in iface.ipv6_gateways:
            routes.append({"to": "::/0", "via": gw, "table": table_id})
        for subnet in iface.ipv6_subnets:
            policy.append({"from": subnet, "table": table_id})

        if routes:
            pbr_ethernets[iface.name] = {
                "routes": routes,
                "routing-policy": policy,
            }

        table_id += 10

    return {"network": {"version": 2, "ethernets": pbr_ethernets}}

# ── YAML 输出 ─────────────────────────────────────────────────────────────────

def dump_yaml(data: dict[str, Any]) -> str:
    return yaml.dump(
        data,
        default_flow_style=False,
        allow_unicode=True,
        sort_keys=False,
        width=120,
    )


def write_config(path: Path, data: dict[str, Any], description: str) -> None:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    header = (
        f"# {path.name}\n"
        f"# {description}\n"
        f"# 由 setup-pbr.py 自动生成 · {now}\n"
    )
    path.write_text(header + dump_yaml(data), encoding="utf-8")

# ── 备份与回滚 ────────────────────────────────────────────────────────────────

def backup_cloud_init(src: Path) -> Path:
    """备份并禁用原始 cloud-init 配置，返回备份路径"""
    bak = src.with_suffix(".yaml.bak")
    if not bak.exists():
        shutil.copy2(src, bak)
        Log.ok(f"已备份: {src} -> {bak}")
    # 重命名使 Netplan 不再加载
    if src.exists() and src.suffix == ".yaml":
        src.rename(bak)
        Log.ok(f"已禁用原始配置: {src} -> {bak}")
    return bak

# ── 应用配置 ──────────────────────────────────────────────────────────────────

def apply_netplan() -> bool:
    """执行 netplan try，返回是否成功"""
    Log.info("正在执行 netplan try（120 秒内未确认将自动回滚）...")
    result = subprocess.run(["netplan", "try"], check=False)
    return result.returncode == 0

# ── 打印辅助 ──────────────────────────────────────────────────────────────────

def print_file(path: Path) -> None:
    Log.info(f"===== {path.name} =====")
    print(path.read_text(encoding="utf-8"))


def print_verification() -> None:
    print()
    Log.info("验证命令：")
    cmds = [
        ("ip route show",              "IPv4 主路由表"),
        ("ip -6 route show",           "IPv6 主路由表"),
        ("ip rule show",               "IPv4 策略路由规则"),
        ("ip -6 rule show",            "IPv6 策略路由规则"),
        ("ip route show table 10",     "自定义路由表 10（IPv4）"),
        ("ip -6 route show table 10",  "自定义路由表 10（IPv6）"),
    ]
    for cmd, desc in cmds:
        print(f"    {cmd:<35s}# {desc}")


def print_rollback(cloud_init: Path, ethernet: Path, pbr: Path) -> None:
    bak = cloud_init.with_suffix(".yaml.bak")
    print()
    Log.info("如需回滚：")
    print(f"    sudo mv {bak} {cloud_init}")
    print(f"    sudo rm -f {ethernet} {pbr}")
    print(f"    sudo netplan apply")

# ── 直连域名管理（tcping）──────────────────────────────────────────────────
#
# 用法：
#   sudo python3 setup-pbr.py tcping                  # 交互菜单
#   sudo python3 setup-pbr.py tcping init              # 初始化环境
#   sudo python3 setup-pbr.py tcping add               # 添加条目
#   sudo python3 setup-pbr.py tcping remove            # 删除条目
#   sudo python3 setup-pbr.py tcping list              # 查看列表
#   sudo python3 setup-pbr.py tcping refresh           # 刷新 DNS
#   sudo python3 setup-pbr.py tcping clear             # 清除所有配置
#   sudo python3 setup-pbr.py tcping -i eth2 init      # 指定出口网卡
#
# ──────────────────────────────────────────────────────────────────────────

TCPING_CONF      = Path("/etc/tcping-direct-list.conf")
TCPING_DNSMASQ   = Path("/etc/dnsmasq.d/tcping-direct.conf")
TCPING_BACKEND_F = Path("/etc/tcping_direct_backend")
TCPING_RESOLVER  = Path("/usr/local/bin/tcping-direct-resolve.sh")
TCPING_RESTORE   = Path("/usr/local/bin/restore-tcping-direct.sh")
TCPING_SET_V4    = "tcping_direct"
TCPING_SET_V6    = "tcping_direct6"
TCPING_FWMARK    = 110
TCPING_RT_TABLE  = 200
TCPING_RT_NAME   = "tcping_direct"

_RE_V4     = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")
_RE_V6     = re.compile(r"^[0-9a-fA-F:]+$")
_RE_DOMAIN = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9.\-]*[a-zA-Z0-9])?$")

# ── Shell 辅助 ────────────────────────────────────────────────────────────

def _sh(cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, shell=True, check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )

def _sh_out(cmd: str) -> str:
    r = _sh(cmd, check=False)
    return r.stdout.strip() if r.returncode == 0 else ""

# ── tcping 检测 ───────────────────────────────────────────────────────────

def _tcping_has_nft() -> bool:
    return shutil.which("nft") is not None

def _tcping_find_nft_table() -> str:
    for t in ("qh_mark", "relay_mark"):
        if _sh(f"nft list table inet {t}", check=False).returncode == 0:
            return t
    return ""

def _tcping_read_backend() -> dict[str, str]:
    if not TCPING_BACKEND_F.is_file():
        return {}
    data: dict[str, str] = {}
    for line in TCPING_BACKEND_F.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            data[k] = v
    return data

# ── 输入解析 ──────────────────────────────────────────────────────────────

def _tcping_is_v4(s: str) -> bool:
    return bool(_RE_V4.match(s))

def _tcping_is_v6(s: str) -> bool:
    return bool(_RE_V6.match(s)) and ":" in s

def _tcping_parse_entry(raw: str) -> tuple[str, str] | None:
    """解析用户输入 → (type, value) 或 None"""
    raw = raw.strip()
    if not raw:
        return None
    for prefix in ("http://", "https://"):
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
    raw = raw.split("/")[0]

    if raw.startswith("["):
        inner = raw.lstrip("[").split("]")[0]
        return ("ipv6", inner) if _tcping_is_v6(inner) else None
    if _tcping_is_v4(raw):
        return ("ipv4", raw)
    if _tcping_is_v6(raw):
        return ("ipv6", raw)

    domain = raw.split(":")[0]
    if _RE_DOMAIN.match(domain) and "." in domain:
        return ("domain", domain)
    return None

# ── tcping 显示 ───────────────────────────────────────────────────────────

def _tcping_show_entries() -> None:
    cfg = _tcping_read_backend()
    backend, nft_table = cfg.get("backend", ""), cfg.get("nft_table", "")
    if backend == "nft" and nft_table:
        Log.info("--- IPv4 (nft set) ---")
        out = _sh_out(f"nft list set inet {nft_table} {TCPING_SET_V4} 2>/dev/null")
        found = [l.strip() for l in out.splitlines()
                 if l.strip() and l.strip()[0].isdigit()]
        print("\n".join(found) if found else "  (无)")
        Log.info("--- IPv6 (nft set) ---")
        out = _sh_out(f"nft list set inet {nft_table} {TCPING_SET_V6} 2>/dev/null")
        found = [l.strip() for l in out.splitlines()
                 if l.strip() and l.strip()[0] in "0123456789abcdefABCDEF"]
        print("\n".join(found) if found else "  (无)")
    else:
        Log.info("--- IPv4 (ipset) ---")
        out = _sh_out(f"ipset list {TCPING_SET_V4} 2>/dev/null")
        found = [l for l in out.splitlines() if l and l[0].isdigit()]
        print("\n".join(found) if found else "  (无)")
        Log.info("--- IPv6 (ipset) ---")
        out = _sh_out(f"ipset list {TCPING_SET_V6} 2>/dev/null")
        found = [l for l in out.splitlines()
                 if l and l[0] in "0123456789abcdefABCDEF"]
        print("\n".join(found) if found else "  (无)")

# ── dnsmasq 重生成 ────────────────────────────────────────────────────────

def _tcping_regen_dnsmasq() -> None:
    cfg = _tcping_read_backend()
    backend, nft_table = cfg.get("backend", ""), cfg.get("nft_table", "")
    domains: list[str] = []
    if TCPING_CONF.is_file():
        for line in TCPING_CONF.read_text().splitlines():
            if line.startswith("domain="):
                domains.append(line.split("=", 1)[1])

    lines = [
        "# dnsmasq 直连域名配置 — setup-pbr.py 自动生成",
        "server=8.8.8.8",
        "server=1.1.1.1",
        "listen-address=127.0.0.1",
        "bind-interfaces",
    ]
    for d in domains:
        if backend == "nft" and nft_table:
            lines.append(
                f"nftset=/{d}/4#inet#{nft_table}#{TCPING_SET_V4},"
                f"6#inet#{nft_table}#{TCPING_SET_V6}"
            )
        else:
            lines.append(f"ipset=/{d}/{TCPING_SET_V4},{TCPING_SET_V6}")

    TCPING_DNSMASQ.parent.mkdir(parents=True, exist_ok=True)
    TCPING_DNSMASQ.write_text("\n".join(lines) + "\n")
    _sh("systemctl restart dnsmasq 2>/dev/null || true", check=False)

# ── 生成 bash 脚本 ────────────────────────────────────────────────────────

def _tcping_gen_resolver() -> str:
    """生成定时域名解析脚本"""
    return (
        r'''#!/bin/bash
CONF="__CONF__"
BACKEND_FILE="__BACKEND_F__"
[ -f "$CONF" ] || exit 0
[ -f "$BACKEND_FILE" ] || exit 0

BACKEND=$(grep '^backend=' "$BACKEND_FILE" | cut -d= -f2)
NFT_TABLE=$(grep '^nft_table=' "$BACKEND_FILE" | cut -d= -f2)

add_v4() {
  if [ "$BACKEND" = "nft" ]; then
    nft add element inet "$NFT_TABLE" __SET_V4__ "{ $1 timeout 3600s }" 2>/dev/null
  else
    ipset -exist add __SET_V4__ "$1" timeout 3600
  fi
}
add_v6() {
  if [ "$BACKEND" = "nft" ]; then
    nft add element inet "$NFT_TABLE" __SET_V6__ "{ $1 timeout 3600s }" 2>/dev/null
  else
    ipset -exist add __SET_V6__ "$1" timeout 3600
  fi
}
add_v4_perm() {
  if [ "$BACKEND" = "nft" ]; then
    nft add element inet "$NFT_TABLE" __SET_V4__ "{ $1 }" 2>/dev/null
  else
    ipset -exist add __SET_V4__ "$1" timeout 0
  fi
}
add_v6_perm() {
  if [ "$BACKEND" = "nft" ]; then
    nft add element inet "$NFT_TABLE" __SET_V6__ "{ $1 }" 2>/dev/null
  else
    ipset -exist add __SET_V6__ "$1" timeout 0
  fi
}

is_ipv4() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
is_ipv6() { echo "$1" | grep -qE '^[0-9a-fA-F:]+$' && echo "$1" | grep -q ':.*:.*:'; }

grep '^domain=' "$CONF" | cut -d= -f2 | while IFS= read -r d; do
  [ -z "$d" ] && continue
  dig +short +tries=2 +time=3 "$d" A @8.8.8.8 2>/dev/null | while IFS= read -r ip; do
    is_ipv4 "$ip" && add_v4 "$ip"
  done
  dig +short +tries=2 +time=3 "$d" AAAA @8.8.8.8 2>/dev/null | while IFS= read -r ip6; do
    is_ipv6 "$ip6" && add_v6 "$ip6"
  done
done

grep '^ipv4=' "$CONF" | cut -d= -f2 | while IFS= read -r ip; do
  is_ipv4 "$ip" && add_v4_perm "$ip"
done
grep '^ipv6=' "$CONF" | cut -d= -f2 | while IFS= read -r ip6; do
  is_ipv6 "$ip6" && add_v6_perm "$ip6"
done
'''
        .replace("__CONF__", str(TCPING_CONF))
        .replace("__BACKEND_F__", str(TCPING_BACKEND_F))
        .replace("__SET_V4__", TCPING_SET_V4)
        .replace("__SET_V6__", TCPING_SET_V6)
    )


def _tcping_gen_restore(iface: str) -> str:
    """生成开机恢复脚本（重建 nft 规则 + 策略路由 + 解析域名）"""
    return (
        r'''#!/bin/bash
sleep 3
BACKEND_FILE="__BACKEND_F__"
[ -f "$BACKEND_FILE" ] || exit 0

BACKEND=$(grep '^backend=' "$BACKEND_FILE" | cut -d= -f2)
NFT_TABLE=$(grep '^nft_table=' "$BACKEND_FILE" | cut -d= -f2)
IFACE="__IFACE__"
FWMARK=__FWMARK__
TABLE=__TABLE__

# ── 恢复 nft 规则 ──
if [ "$BACKEND" = "nft" ] && [ -n "$NFT_TABLE" ]; then
  nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || nft add table inet "$NFT_TABLE"
  nft list chain inet "$NFT_TABLE" output >/dev/null 2>&1 || \
    nft "add chain inet $NFT_TABLE output { type route hook output priority -150; policy accept; }"
  nft list set inet "$NFT_TABLE" __SET_V4__ >/dev/null 2>&1 || {
    nft add set inet "$NFT_TABLE" __SET_V4__ '{ type ipv4_addr; flags timeout; }'
    nft add rule inet "$NFT_TABLE" output ip daddr @__SET_V4__ meta mark set $FWMARK
  }
  nft list set inet "$NFT_TABLE" __SET_V6__ >/dev/null 2>&1 || {
    nft add set inet "$NFT_TABLE" __SET_V6__ '{ type ipv6_addr; flags timeout; }'
    nft add rule inet "$NFT_TABLE" output ip6 daddr @__SET_V6__ meta mark set $FWMARK
  }
  nft list chain inet "$NFT_TABLE" tcping_postrouting >/dev/null 2>&1 || {
    nft "add chain inet $NFT_TABLE tcping_postrouting { type nat hook postrouting priority srcnat; policy accept; }"
    nft add rule inet "$NFT_TABLE" tcping_postrouting meta mark $FWMARK masquerade
  }
fi

# ── 恢复策略路由 ──
ip -4 rule del fwmark $FWMARK table $TABLE 2>/dev/null
ip -6 rule del fwmark $FWMARK table $TABLE 2>/dev/null

V4_GW=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '/via/{print $3; exit}')
V6_GW=$(ip -6 route show default dev "$IFACE" 2>/dev/null | awk '/via/{print $3; exit}')
if [ -z "$V6_GW" ]; then
  V6_GW=$(ip -6 neigh show dev "$IFACE" 2>/dev/null | grep router | head -1 | awk '{print $1}')
fi

if [ -n "$V4_GW" ]; then
  ip -4 route replace default via "$V4_GW" dev "$IFACE" table $TABLE
  ip -4 rule add fwmark $FWMARK table $TABLE
fi
if [ -n "$V6_GW" ]; then
  ip -6 route replace default via "$V6_GW" dev "$IFACE" table $TABLE
  ip -6 rule add fwmark $FWMARK table $TABLE
elif ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -q inet6; then
  ip -6 route replace default dev "$IFACE" table $TABLE
  ip -6 rule add fwmark $FWMARK table $TABLE
fi

# ── 解析域名 ──
__RESOLVER__ 2>/dev/null || true
'''
        .replace("__BACKEND_F__", str(TCPING_BACKEND_F))
        .replace("__IFACE__", iface)
        .replace("__FWMARK__", str(TCPING_FWMARK))
        .replace("__TABLE__", str(TCPING_RT_TABLE))
        .replace("__SET_V4__", TCPING_SET_V4)
        .replace("__SET_V6__", TCPING_SET_V6)
        .replace("__RESOLVER__", str(TCPING_RESOLVER))
    )

# ── tcping 核心操作 ───────────────────────────────────────────────────────

def tcping_setup(iface: str) -> None:
    """初始化直连域名环境"""
    if os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行"); return

    Log.info("安装 dnsmasq、ipset、dnsutils...")
    r = _sh(
        "apt-get update -qq"
        " && apt-get install -y -qq dnsmasq ipset dnsutils >/dev/null 2>&1",
        check=False,
    )
    if r.returncode != 0:
        Log.err("安装失败"); return

    Log.info("停止 systemd-resolved（避免端口冲突）...")
    _sh("systemctl disable --now systemd-resolved 2>/dev/null || true", check=False)

    # ── 防火墙后端 ──
    Log.info("检测防火墙后端...")
    if _tcping_has_nft():
        nft_table = _tcping_find_nft_table()
        if not nft_table:
            nft_table = "tcping_mark"
            Log.warn(f"未找到已有 nft 标记表，创建: {nft_table}")
            _sh(f"nft add table inet {nft_table}")
            _sh(
                f"nft 'add chain inet {nft_table} output"
                f" {{ type route hook output priority -150; policy accept; }}'"
            )
        backend = "nft"
        Log.info(f"使用 nft 后端，表: {nft_table}")
    else:
        backend, nft_table = "iptables", ""
        Log.info("使用 iptables 后端")

    TCPING_BACKEND_F.write_text(
        f"backend={backend}\nnft_table={nft_table}\niface={iface}\n"
    )

    # ── nft sets / ipset + 标记规则 ──
    if backend == "nft":
        _sh(
            f"nft list set inet {nft_table} {TCPING_SET_V4} >/dev/null 2>&1 || {{"
            f" nft add set inet {nft_table} {TCPING_SET_V4}"
            f" '{{ type ipv4_addr; flags timeout; }}';"
            f" nft add rule inet {nft_table} output"
            f" ip daddr @{TCPING_SET_V4} meta mark set {TCPING_FWMARK};"
            f" }}"
        )
        _sh(
            f"nft list set inet {nft_table} {TCPING_SET_V6} >/dev/null 2>&1 || {{"
            f" nft add set inet {nft_table} {TCPING_SET_V6}"
            f" '{{ type ipv6_addr; flags timeout; }}';"
            f" nft add rule inet {nft_table} output"
            f" ip6 daddr @{TCPING_SET_V6} meta mark set {TCPING_FWMARK};"
            f" }}"
        )
    else:
        _sh(f"ipset create {TCPING_SET_V4} hash:ip timeout 0 2>/dev/null || true",
            check=False)
        _sh(f"ipset create {TCPING_SET_V6} hash:ip family inet6 timeout 0"
            " 2>/dev/null || true", check=False)
        _sh(
            f"iptables -t mangle -C OUTPUT -m set --match-set {TCPING_SET_V4} dst"
            f" -j MARK --set-mark {TCPING_FWMARK} 2>/dev/null ||"
            f" iptables -t mangle -A OUTPUT -m set --match-set {TCPING_SET_V4} dst"
            f" -j MARK --set-mark {TCPING_FWMARK}"
        )
        _sh(
            f"ip6tables -t mangle -C OUTPUT -m set --match-set {TCPING_SET_V6} dst"
            f" -j MARK --set-mark {TCPING_FWMARK} 2>/dev/null ||"
            f" ip6tables -t mangle -A OUTPUT -m set --match-set {TCPING_SET_V6} dst"
            f" -j MARK --set-mark {TCPING_FWMARK}",
            check=False,
        )
    Log.ok("防火墙标记规则已配置")

    # ── MASQUERADE ──
    Log.info("配置 MASQUERADE...")
    if backend == "nft":
        _sh(
            f"nft list chain inet {nft_table} tcping_postrouting >/dev/null 2>&1 ||"
            f" nft 'add chain inet {nft_table} tcping_postrouting"
            f" {{ type nat hook postrouting priority srcnat; policy accept; }}'"
        )
        _sh(
            f"nft add rule inet {nft_table} tcping_postrouting"
            f" meta mark {TCPING_FWMARK} masquerade"
        )
    else:
        _sh(
            f"iptables -t nat -C POSTROUTING -m mark --mark {TCPING_FWMARK}"
            f" -j MASQUERADE 2>/dev/null ||"
            f" iptables -t nat -A POSTROUTING -m mark --mark {TCPING_FWMARK}"
            f" -j MASQUERADE"
        )
        _sh(
            f"ip6tables -t nat -C POSTROUTING -m mark --mark {TCPING_FWMARK}"
            f" -j MASQUERADE 2>/dev/null ||"
            f" ip6tables -t nat -A POSTROUTING -m mark --mark {TCPING_FWMARK}"
            f" -j MASQUERADE",
            check=False,
        )

    # ── 策略路由：fwmark → 自定义表 → 指定出口 ──
    Log.info(f"配置策略路由（出口: {iface}）...")

    v4_gw = _sh_out(
        f"ip -4 route show default dev {iface} 2>/dev/null"
        " | awk '/via/{print $3; exit}'"
    )
    v6_gw = _sh_out(
        f"ip -6 route show default dev {iface} 2>/dev/null"
        " | awk '/via/{print $3; exit}'"
    )
    if not v6_gw:
        v6_gw = _sh_out(
            f"ip -6 neigh show dev {iface} 2>/dev/null"
            " | grep router | head -1 | awk '{print $1}'"
        )
    has_v6 = bool(_sh_out(
        f"ip -6 addr show dev {iface} scope global 2>/dev/null | grep -m1 inet6"
    ))

    rt_tables = Path("/etc/iproute2/rt_tables")
    if rt_tables.is_file():
        rt_text = rt_tables.read_text()
        if TCPING_RT_NAME not in rt_text:
            with rt_tables.open("a") as f:
                f.write(f"\n{TCPING_RT_TABLE}\t{TCPING_RT_NAME}\n")

    if v4_gw:
        _sh(f"ip -4 route replace default via {v4_gw} dev {iface}"
            f" table {TCPING_RT_TABLE}", check=False)
        _sh(f"ip -4 rule del fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}"
            " 2>/dev/null || true", check=False)
        _sh(f"ip -4 rule add fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}")
        Log.ok(f"IPv4: fwmark {TCPING_FWMARK} → via {v4_gw} dev {iface}")
    else:
        Log.warn(f"{iface} 无 IPv4 默认网关，跳过 IPv4 策略路由")

    if v6_gw:
        _sh(f"ip -6 route replace default via {v6_gw} dev {iface}"
            f" table {TCPING_RT_TABLE}", check=False)
        _sh(f"ip -6 rule del fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}"
            " 2>/dev/null || true", check=False)
        _sh(f"ip -6 rule add fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}")
        Log.ok(f"IPv6: fwmark {TCPING_FWMARK} → via {v6_gw} dev {iface}")
    elif has_v6:
        _sh(f"ip -6 route replace default dev {iface}"
            f" table {TCPING_RT_TABLE}", check=False)
        _sh(f"ip -6 rule del fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}"
            " 2>/dev/null || true", check=False)
        _sh(f"ip -6 rule add fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}")
        Log.ok(f"IPv6: fwmark {TCPING_FWMARK} → dev {iface}")
    else:
        Log.warn(f"{iface} 无 IPv6 地址/网关，跳过 IPv6 策略路由")

    # ── 配置文件 ──
    Log.info("初始化配置文件...")
    Path("/etc/dnsmasq.d").mkdir(parents=True, exist_ok=True)
    if not TCPING_CONF.is_file():
        TCPING_CONF.write_text(
            "# 直连列表 — setup-pbr.py 管理\n"
            "# domain=域名 | ipv4=地址 | ipv6=地址\n"
        )

    _tcping_regen_dnsmasq()

    dnsmasq_main = Path("/etc/dnsmasq.conf")
    if dnsmasq_main.is_file():
        if "conf-dir=/etc/dnsmasq.d" not in dnsmasq_main.read_text():
            with dnsmasq_main.open("a") as f:
                f.write("\nconf-dir=/etc/dnsmasq.d/,*.conf\n")

    Log.info("配置本机 DNS...")
    _sh("chattr -i /etc/resolv.conf 2>/dev/null || true", check=False)
    resolv = Path("/etc/resolv.conf")
    if resolv.is_symlink():
        resolv.unlink()
    resolv.write_text("nameserver 127.0.0.1\nnameserver 8.8.8.8\n")
    _sh("chattr +i /etc/resolv.conf 2>/dev/null || true", check=False)

    _sh("systemctl enable --now dnsmasq", check=False)
    if _sh("systemctl restart dnsmasq", check=False).returncode != 0:
        Log.warn("dnsmasq 启动失败，请检查: journalctl -xeu dnsmasq.service")

    # ── 脚本 + systemd ──
    Log.info("创建定时解析脚本...")
    TCPING_RESOLVER.write_text(_tcping_gen_resolver())
    TCPING_RESOLVER.chmod(0o755)
    TCPING_RESTORE.write_text(_tcping_gen_restore(iface))
    TCPING_RESTORE.chmod(0o755)

    Log.info("配置 systemd 定时服务...")
    Path("/etc/systemd/system/tcping-direct-resolve.service").write_text(
        f"[Unit]\nDescription=Resolve tcping direct domains\n\n"
        f"[Service]\nType=oneshot\nExecStart={TCPING_RESOLVER}\n"
    )
    Path("/etc/systemd/system/tcping-direct-resolve.timer").write_text(
        "[Unit]\nDescription=Periodic tcping direct DNS resolve\n\n"
        "[Timer]\nOnBootSec=60\nOnUnitActiveSec=600\n\n"
        "[Install]\nWantedBy=timers.target\n"
    )
    Path("/etc/systemd/system/tcping-direct.service").write_text(
        f"[Unit]\nDescription=Restore tcping direct entries\n"
        f"After=network-online.target dnsmasq.service\n"
        f"Wants=network-online.target\n\n"
        f"[Service]\nType=oneshot\nExecStart={TCPING_RESTORE}\n"
        f"RemainAfterExit=yes\n\n"
        f"[Install]\nWantedBy=multi-user.target\n"
    )
    _sh("systemctl daemon-reload")
    _sh("systemctl enable --now tcping-direct-resolve.timer")
    _sh("systemctl enable tcping-direct.service")

    Log.info("执行首次域名解析...")
    _sh(str(TCPING_RESOLVER), check=False)

    print()
    Log.ok("直连域名环境初始化完成！")
    Log.info(f"出口网卡: {iface}")
    Log.info("子域名通过 dnsmasq 自动匹配（添加 oojj.de 即覆盖 *.oojj.de）")


def tcping_add() -> None:
    """添加直连条目（域名 / IPv4 / IPv6）"""
    if os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行"); return
    if not TCPING_CONF.is_file():
        Log.err("尚未初始化，请先执行「初始化直连环境」"); return

    print()
    Log.info("输入域名或 IP（每行一个，空行结束）:")
    Log.info("示例: oojj.de | 1.2.3.4 | 2408:8756::1 | [2408:8756::1]")
    domains: list[str] = []
    ipv4s:   list[str] = []
    ipv6s:   list[str] = []
    while True:
        try:
            raw = input("> ")
        except (EOFError, KeyboardInterrupt):
            print(); break
        if not raw.strip():
            break
        parsed = _tcping_parse_entry(raw)
        if parsed is None:
            Log.warn(f"无效格式: {raw}"); continue
        ptype, pval = parsed
        {"domain": domains, "ipv4": ipv4s, "ipv6": ipv6s}[ptype].append(pval)

    if not (domains or ipv4s or ipv6s):
        Log.warn("未输入任何有效条目"); return

    existing = TCPING_CONF.read_text()
    has_new_domain = False

    for d in domains:
        if f"domain={d}\n" in existing:
            Log.warn(f"已存在: {d}")
        else:
            with TCPING_CONF.open("a") as f:
                f.write(f"domain={d}\n")
            Log.info(f"已添加域名: {d}（含子域名）")
            has_new_domain = True

    for ip in ipv4s:
        if f"ipv4={ip}\n" in existing:
            Log.warn(f"已存在: {ip}")
        else:
            with TCPING_CONF.open("a") as f:
                f.write(f"ipv4={ip}\n")
            Log.info(f"已添加 IPv4: {ip}")

    for ip6 in ipv6s:
        if f"ipv6={ip6}\n" in existing:
            Log.warn(f"已存在: {ip6}")
        else:
            with TCPING_CONF.open("a") as f:
                f.write(f"ipv6={ip6}\n")
            Log.info(f"已添加 IPv6: {ip6}")

    if has_new_domain:
        Log.info("重新生成 dnsmasq 配置...")
        _tcping_regen_dnsmasq()

    Log.info("执行域名解析...")
    _sh(str(TCPING_RESOLVER), check=False)

    print()
    Log.ok("添加完成！当前匹配条目：")
    _tcping_show_entries()


def tcping_remove() -> None:
    """删除直连条目"""
    if os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行"); return
    if not TCPING_CONF.is_file():
        Log.err("尚未初始化"); return

    entries: list[tuple[str, str]] = []
    for line in TCPING_CONF.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            etype, evalue = line.split("=", 1)
            if etype in ("domain", "ipv4", "ipv6"):
                entries.append((etype, evalue))

    if not entries:
        Log.info("当前无条目"); return

    label_map = {"domain": "域名", "ipv4": "IPv4", "ipv6": "IPv6"}
    print()
    Log.info("当前直连列表：")
    for i, (etype, evalue) in enumerate(entries, 1):
        print(f"  {i}) [{label_map[etype]}] {evalue}")

    print()
    try:
        sel = input("输入要删除的序号（空格分隔，a=全部）: ").strip()
    except (EOFError, KeyboardInterrupt):
        print(); return
    if not sel:
        return

    to_remove: list[int] = []
    if sel.lower() == "a":
        to_remove = list(range(len(entries)))
    else:
        for s in sel.split():
            try:
                idx = int(s) - 1
                if 0 <= idx < len(entries):
                    to_remove.append(idx)
                else:
                    Log.warn(f"序号超范围: {s}")
            except ValueError:
                Log.warn(f"无效序号: {s}")

    if not to_remove:
        Log.warn("未选中有效条目"); return

    text = TCPING_CONF.read_text()
    has_domain_change = False
    for idx in sorted(set(to_remove), reverse=True):
        etype, evalue = entries[idx]
        text = text.replace(f"{etype}={evalue}\n", "", 1)
        Log.info(f"已删除 [{label_map[etype]}] {evalue}")
        if etype == "domain":
            has_domain_change = True
    TCPING_CONF.write_text(text)

    if has_domain_change:
        Log.info("重新生成 dnsmasq 配置...")
        _tcping_regen_dnsmasq()

    Log.info("重新解析所有条目...")
    cfg = _tcping_read_backend()
    backend, nft_table = cfg.get("backend", ""), cfg.get("nft_table", "")
    if backend == "nft" and nft_table:
        _sh(f"nft flush set inet {nft_table} {TCPING_SET_V4}"
            " 2>/dev/null || true", check=False)
        _sh(f"nft flush set inet {nft_table} {TCPING_SET_V6}"
            " 2>/dev/null || true", check=False)
    else:
        _sh(f"ipset flush {TCPING_SET_V4} 2>/dev/null || true", check=False)
        _sh(f"ipset flush {TCPING_SET_V6} 2>/dev/null || true", check=False)
    _sh(str(TCPING_RESOLVER), check=False)

    Log.ok("删除完成")


def tcping_list() -> None:
    """查看直连列表"""
    if not TCPING_CONF.is_file():
        Log.err("尚未初始化，请先执行「初始化直连环境」"); return

    label_map = {"domain": "域名", "ipv4": "IPv4", "ipv6": "IPv6"}

    print("\n==============================")
    print(" 当前直连列表")
    print("==============================")
    entries = [
        l for l in TCPING_CONF.read_text().splitlines()
        if "=" in l and not l.startswith("#")
    ]
    if not entries:
        Log.info("(无条目)")
    else:
        for i, line in enumerate(entries, 1):
            etype, evalue = line.split("=", 1)
            print(f"  {i}) [{label_map.get(etype, etype)}] {evalue}")

    print("\n==============================")
    print(" 已匹配的 IP 条目")
    print("==============================")
    _tcping_show_entries()

    cfg = _tcping_read_backend()
    print()
    Log.info(f"出口网卡: {cfg.get('iface', '未配置')}")
    Log.info(
        "dnsmasq: "
        + _sh_out("systemctl is-active dnsmasq 2>/dev/null || echo inactive")
    )


def tcping_refresh() -> None:
    """刷新 DNS 解析"""
    if os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行"); return
    if not TCPING_CONF.is_file():
        Log.err("尚未初始化"); return

    cfg = _tcping_read_backend()
    backend, nft_table = cfg.get("backend", ""), cfg.get("nft_table", "")

    Log.info("清空条目并重新解析...")
    if backend == "nft" and nft_table:
        _sh(f"nft flush set inet {nft_table} {TCPING_SET_V4}"
            " 2>/dev/null || true", check=False)
        _sh(f"nft flush set inet {nft_table} {TCPING_SET_V6}"
            " 2>/dev/null || true", check=False)
    else:
        _sh(f"ipset flush {TCPING_SET_V4} 2>/dev/null || true", check=False)
        _sh(f"ipset flush {TCPING_SET_V6} 2>/dev/null || true", check=False)

    Log.info("重新生成 dnsmasq 配置...")
    _tcping_regen_dnsmasq()

    _sh(str(TCPING_RESOLVER), check=False)
    print()
    Log.ok("DNS 刷新完成！")
    _tcping_show_entries()


def tcping_clear() -> None:
    """清除所有直连域名配置"""
    if os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行"); return

    try:
        confirm = input(
            f"{Log.YELLOW}确认清除所有直连域名配置？[y/N]: {Log.NC}"
        ).strip().lower()
    except (EOFError, KeyboardInterrupt):
        print(); return
    if confirm != "y":
        Log.info("已取消"); return

    cfg = _tcping_read_backend()
    backend  = cfg.get("backend", "")
    nft_table = cfg.get("nft_table", "")

    # 防火墙
    Log.info("清除防火墙规则...")
    if backend == "nft":
        for t in {nft_table, "qh_mark", "relay_mark", "tcping_mark"} - {""}:
            _sh(f"nft delete chain inet {t} tcping_postrouting"
                " 2>/dev/null || true", check=False)
            _sh(f"nft delete set inet {t} {TCPING_SET_V4}"
                " 2>/dev/null || true", check=False)
            _sh(f"nft delete set inet {t} {TCPING_SET_V6}"
                " 2>/dev/null || true", check=False)
        if nft_table == "tcping_mark":
            _sh("nft delete table inet tcping_mark 2>/dev/null || true",
                check=False)
    else:
        for cmd in (
            f"iptables -t mangle -D OUTPUT -m set --match-set"
            f" {TCPING_SET_V4} dst -j MARK --set-mark {TCPING_FWMARK}",
            f"ip6tables -t mangle -D OUTPUT -m set --match-set"
            f" {TCPING_SET_V6} dst -j MARK --set-mark {TCPING_FWMARK}",
            f"iptables -t nat -D POSTROUTING -m mark"
            f" --mark {TCPING_FWMARK} -j MASQUERADE",
            f"ip6tables -t nat -D POSTROUTING -m mark"
            f" --mark {TCPING_FWMARK} -j MASQUERADE",
        ):
            _sh(f"{cmd} 2>/dev/null || true", check=False)

    Log.info("删除 ipset...")
    _sh(f"ipset destroy {TCPING_SET_V4} 2>/dev/null || true", check=False)
    _sh(f"ipset destroy {TCPING_SET_V6} 2>/dev/null || true", check=False)

    # 策略路由
    Log.info("清除策略路由...")
    _sh(f"ip -4 rule del fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}"
        " 2>/dev/null || true", check=False)
    _sh(f"ip -6 rule del fwmark {TCPING_FWMARK} table {TCPING_RT_TABLE}"
        " 2>/dev/null || true", check=False)
    _sh(f"ip -4 route del default table {TCPING_RT_TABLE}"
        " 2>/dev/null || true", check=False)
    _sh(f"ip -6 route del default table {TCPING_RT_TABLE}"
        " 2>/dev/null || true", check=False)

    # 配置文件
    Log.info("清除配置文件...")
    for p in (TCPING_CONF, TCPING_DNSMASQ, TCPING_BACKEND_F):
        p.unlink(missing_ok=True)
    _sh("systemctl restart dnsmasq 2>/dev/null || true", check=False)

    Log.info("恢复 DNS...")
    _sh("chattr -i /etc/resolv.conf 2>/dev/null || true", check=False)
    Path("/etc/resolv.conf").write_text(
        "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"
    )

    # systemd
    Log.info("清除 systemd 服务...")
    _sh("systemctl disable --now tcping-direct-resolve.timer"
        " 2>/dev/null || true", check=False)
    _sh("systemctl disable --now tcping-direct.service"
        " 2>/dev/null || true", check=False)
    for p in (
        Path("/etc/systemd/system/tcping-direct-resolve.timer"),
        Path("/etc/systemd/system/tcping-direct-resolve.service"),
        Path("/etc/systemd/system/tcping-direct.service"),
        TCPING_RESTORE,
        TCPING_RESOLVER,
    ):
        p.unlink(missing_ok=True)
    _sh("systemctl daemon-reload")

    print()
    Log.ok("直连域名配置已完全清除")

# ── tcping 菜单 ───────────────────────────────────────────────────────────

def tcping_menu(default_iface: str) -> None:
    """交互式直连域名管理菜单"""
    menu_text = """
==============================
 直连域名管理（tcping）
==============================
1) 初始化直连环境
2) 添加条目（域名/IPv4/IPv6）
3) 删除条目
4) 查看列表和 ipset
5) 刷新 DNS 解析
6) 清除所有配置
q) 退出"""

    while True:
        print(menu_text)
        try:
            choice = input("请选择: ").strip()
        except (EOFError, KeyboardInterrupt):
            print(); break
        print()
        if   choice == "1": tcping_setup(default_iface)
        elif choice == "2": tcping_add()
        elif choice == "3": tcping_remove()
        elif choice == "4": tcping_list()
        elif choice == "5": tcping_refresh()
        elif choice == "6": tcping_clear()
        elif choice.lower() == "q": break
        else: Log.warn("无效选项")
        print()


def tcping_main() -> None:
    """tcping 子命令入口"""
    parser = argparse.ArgumentParser(
        prog="setup-pbr.py tcping",
        description="直连域名管理（tcping）— 指定域名/IP 绕过隧道直连",
    )
    parser.add_argument(
        "--iface", "-i", default="eth1",
        help="出口网卡（默认 eth1）",
    )
    parser.add_argument(
        "action", nargs="?", default=None,
        choices=["init", "add", "remove", "list", "refresh", "clear"],
        help="操作（不指定则进入交互菜单）",
    )
    args = parser.parse_args(sys.argv[2:])

    actions: dict[str, Any] = {
        "init":    lambda: tcping_setup(args.iface),
        "add":     tcping_add,
        "remove":  tcping_remove,
        "list":    tcping_list,
        "refresh": tcping_refresh,
        "clear":   tcping_clear,
    }

    if args.action:
        actions[args.action]()
    else:
        tcping_menu(args.iface)

# ── 主流程 ────────────────────────────────────────────────────────────────────

def main() -> None:
    # 直连域名管理子命令：setup-pbr.py tcping [...]
    if len(sys.argv) > 1 and sys.argv[1] == "tcping":
        tcping_main()
        return

    parser = argparse.ArgumentParser(
        description="多网卡 / 多出口 VM 一键策略路由配置（Netplan PBR）",
    )
    parser.add_argument(
        "config",
        nargs="?",
        default="/etc/netplan/50-cloud-init.yaml",
        help="cloud-init 生成的 netplan 配置文件路径（默认 /etc/netplan/50-cloud-init.yaml）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="仅预览生成的配置，不写入文件、不应用",
    )
    args = parser.parse_args()

    cloud_init_path = Path(args.config)
    netplan_dir     = cloud_init_path.parent
    ethernet_path   = netplan_dir / "60-ethernet.yaml"
    pbr_path        = netplan_dir / "90-pbr.yaml"
    dry_run: bool   = args.dry_run

    # ── 前置检查 ──
    if not dry_run and os.geteuid() != 0:
        Log.err("请使用 root 或 sudo 执行此脚本")
        sys.exit(1)

    if not dry_run and not shutil.which("netplan"):
        Log.err("未找到 netplan，此脚本仅适用于使用 Netplan 的系统")
        sys.exit(1)

    if not cloud_init_path.is_file():
        Log.err(f"找不到配置文件: {cloud_init_path}")
        sys.exit(1)

    Log.info(f"源配置文件: {cloud_init_path}")
    if dry_run:
        Log.warn("Dry-run 模式：仅预览，不写入文件")

    # ── 解析 ──
    config     = parse_netplan(cloud_init_path)
    interfaces = extract_interfaces(config)
    routed     = [i for i in interfaces if i.has_default_route]

    if len(routed) < 2:
        Log.warn(
            f"仅发现 {len(routed)} 个带默认路由的接口，策略路由通常需要 >= 2 个"
        )
        if len(routed) == 0:
            Log.err("没有可配置的接口，退出")
            sys.exit(1)

    metrics = assign_metrics(len(routed))

    print()
    Log.info(f"发现 {len(routed)} 个带默认路由的接口：")
    for i, iface in enumerate(routed):
        print(f"         - {iface.summary()}  metric={metrics[i]}")

    # ── 生成配置 ──
    ethernet_data = generate_ethernet_config(config, routed, metrics)
    pbr_data      = generate_pbr_config(routed)

    # ── Dry-run：打印后退出 ──
    if dry_run:
        print()
        Log.info(f"===== {ethernet_path.name}（预览） =====")
        print(dump_yaml(ethernet_data))
        Log.info(f"===== {pbr_path.name}（预览） =====")
        print(dump_yaml(pbr_data))
        print_verification()
        return

    # ── 写入文件 ──
    backup_cloud_init(cloud_init_path)

    write_config(ethernet_path, ethernet_data, "基于 cloud-init 配置添加 metric")
    Log.ok(f"已生成: {ethernet_path}")

    write_config(pbr_path, pbr_data, "策略路由（PBR）配置")
    Log.ok(f"已生成: {pbr_path}")

    # ── 展示配置 ──
    print()
    print_file(ethernet_path)
    print_file(pbr_path)

    # ── 应用 ──
    Log.warn("如果您通过 SSH 连接，请确保有备用访问方式（如控制台）")
    print()
    try:
        confirm = input(f"{Log.YELLOW}是否立即应用？[y/N]: {Log.NC}").strip().lower()
    except (EOFError, KeyboardInterrupt):
        confirm = "n"
        print()

    if confirm == "y":
        if apply_netplan():
            Log.ok("配置已成功应用！")
        else:
            Log.err("netplan try 失败或已回滚，请检查配置文件")
            sys.exit(1)
    else:
        Log.info("已跳过应用，你可以稍后手动执行:")
        print("    sudo netplan try")

    # ── 后续提示 ──
    print_verification()
    print_rollback(cloud_init_path, ethernet_path, pbr_path)


if __name__ == "__main__":
    main()
