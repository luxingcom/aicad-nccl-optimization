#!/bin/bash
# =============================================================
# SCRIPT: probe_ring_topology.sh
# VERSION: v1.0 (2026-09-19)
# ROLE: 实测四机环网物理拓扑（唯一探针 IP + ip neigh 读对端 MAC），
#       生成 topology.json 供 gen_devmap.py 生成 NCCL_RING_DEV_MAP。
#       —— 实录教训①「物理层优先」的落地：接线对不对，以本工具实测为准，
#          不相信文档、不相信记忆、不相信别人的拓扑图。
# USAGE:
#   bash probe_ring_topology.sh --ips 192.168.5.130,192.168.5.17,192.168.5.18,192.168.5.129 \
#        --ranks 0,1,2,3 --ring-ips 10.100.0.1,10.100.1.1,... [--out topology.json]
#   （--ring-ips：按 rank 顺序给出每台机的环网 IP 列表，逗号分隔各机，机内多 IP 用 + 分隔；
#     本脚本只对这些 IP 做连通性探测；MAC 对照需要 root 时自动加 sudo。）
# 更实用形态（在 head 上，逐邻探测）：
#   bash probe_ring_topology.sh --ping 10.100.0.1,10.100.0.2,10.100.1.1,10.100.1.2 \
#        --label rank0-probe [--out probe-rank0.json]
#   # 在每台机对本机全部环网 IP 探一轮，把 4 份 JSON 交给 gen_devmap.py 前人工/脚本比对
# EXITCODES: 0=探测完成 1=存在不可达 IP 2=用法错误
# NOTE:
#   - 探测原理：向本机网段内候选 IP 发 1 个 ICMP ping（-c1 -W1），随后读 `ip neigh`
#     中对应条目的 MAC。两台机器物理直连 ⇔ 同一 /29 子网 ⇔ 能拿到对方 MAC。
#   - 唯一探针 IP：给每个候选段只配一台探测机，避免多机并发探测互相污染 neigh 表。
#   - 本脚本只读不写网络配置（不改 netplan/IP）。
# CHANGE: 改脚本须 bash -n + .bak-<tag> 留档 + 更新 tools/README.md
# =============================================================
set -uo pipefail

OUT=""
LABEL="probe"
declare -a GROUPS=()

usage() { grep -E '^# (USAGE|EXITCODES|NOTE|ROLE)' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ping)  IFS=',' read -ra GROUPS <<< "${2:-}"; shift 2 ;;
    --label) LABEL="${2:-probe}"; shift 2 ;;
    --out)   OUT="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

[ ${#GROUPS[@]} -eq 0 ] && { echo "必须提供 --ping <ip[,ip...]>（本机环网口候选 IP 列表）" >&2; usage; }

PING_BIN=$(command -v ping || true)
[ -z "$PING_BIN" ] && { echo "未找到 ping 命令" >&2; exit 1; }

# 提升 ip neigh 精度：先确保本机这些 IP 已配置（只读检查）
echo "[probe][$LABEL] 本机地址："
ip -o addr show | awk '{print "  ", $2, $4}'

RESULT='{"label":"'"$LABEL"'","probes":['
FIRST=1
UNREACH=0
for ip in "${GROUPS[@]}"; do
  # 1. 探测
  if "$PING_BIN" -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    REACH=1
  else
    REACH=0
  fi
  # 2. 读 neigh（可能需要 sudo 无关，ip neigh 通常普通用户可读）
  ENTRY=$(ip neigh show "$ip" 2>/dev/null | head -1)
  MAC=$(echo "$ENTRY" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')
  DEV=$(echo "$ENTRY"  | awk '{for(i=1;i<=NF;i++) if($i=="dev")     print $(i+1)}')
  STATE=$(echo "$ENTRY"| awk '{for(i=1;i<=NF;i++) if($i=="REACHABLE"||$i=="STALE"||$i=="DELAY"||$i=="PROBE") print $i}')
  [ "$REACH" = "1" ] && [ -z "$MAC" ] && STATE="REACHABLE_NO_MAC(异常:ping通但拿不到MAC,检查arp/sysctl)"
  [ "$REACH" = "0" ] && UNREACH=$((UNREACH+1))
  STATUS=$([ "$REACH" = "1" ] && echo ok || echo unreachable)
  echo "[probe][$LABEL] $ip -> ${STATUS}${MAC:+ mac=$MAC}${DEV:+ dev=$DEV}${STATE:+ state=$STATE}"
  [ $FIRST = 0 ] && RESULT="$RESULT,"
  RESULT="$RESULT{\"ip\":\"$ip\",\"reachable\":$REACH,\"mac\":\"${MAC:-}\",\"iface\":\"${DEV:-}\",\"state\":\"${STATE:-}\"}"
  FIRST=0
done
RESULT="$RESULT]}"

if [ -n "$OUT" ]; then
  printf '%s\n' "$RESULT" > "$OUT"
  echo "[probe][$LABEL] 已写 $OUT"
fi
[ $UNREACH -gt 0 ] && { echo "[probe][$LABEL] x $UNREACH 个 IP 不可达 —— 按实录纪律先查物理层（线插对没/口对应没/IP 段配对没）" >&2; exit 1; }
exit 0
