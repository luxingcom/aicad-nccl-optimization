#!/bin/bash
# lutune.sh — NIC/RoCE 参数集应用器（幂等；读现值→等值跳过→差值才写）
# 部署位：/opt/dsv41-mesh/bin/lutune.sh（四机同体）
# 谱系：KNAPCIO-FABRIC-TUNING-20261007.md §二 P 表 + §五主会话裁定
#   【本窗已批定值（裁定 7 可直定项）】
#     P1 ring rx=8192（16 口全量；TX 不动——当前 1024，任务书令 TX 不碰）
#   【断言不动作项】（各自归属域，lutune 只读核对）
#     P5 MTU=9000（netplan/mesh 域）  P6 hairpin=8192（dsv41-mesh.service boot 重放域）
#     P4 trust=pcp（qos.sh 域，ring 模板维持）
#   【未装项（§五裁定 1：依据不足待哨兵基线，本窗不装）】
#     P2 prio0 收缓冲扩容（现 19,872B 出厂）  P3 PFC prio0 激进档
# 幂等律：重复 apply 零动作（同 hairpin.sh 模式）；任一口失败=退出码 1（fail-open 留痕给
#   lutune-apply.service，不阻 boot——参数面缺失不应使机器不可用，但 journal 高优先级大声）。
set -u
DEVLIST="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
RX_TARGET=4096
rc=0

cur_rx() { ethtool -g "$1" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f&&/^RX:/{print $2; exit}'; }
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else printf '%s\n' "$(cat ~/.sudopw 2>/dev/null)" | sudo -S "$@" 2>/dev/null; fi; }

for d in $DEVLIST; do
  c=$(cur_rx "$d")
  if [ -z "$c" ]; then echo "[lutune] WARN $d 读值失败（口不在？）"; rc=1; continue; fi
  if [ "$c" = "$RX_TARGET" ]; then
    echo "[lutune] $d rx 已=${RX_TARGET}（幂等跳过）"
  else
    if as_root ethtool -G "$d" rx "$RX_TARGET"; then
      echo "[lutune] $d rx ${c}->${RX_TARGET} 已写"
    else
      echo "[lutune] FAIL $d rx apply 失败"; rc=1
    fi
  fi
done

# 复验段（写后回读）
fail=0
for d in $DEVLIST; do
  c=$(cur_rx "$d")
  [ "$c" = "$RX_TARGET" ] || { echo "[lutune] VERIFY-FAIL $d rx=${c:-none}"; fail=1; }
done

# 断言不动作项（只读核对，异常=WARN 不 FAIL——各域归 mesh 单元管）
for d in $DEVLIST; do
  m=$(ip link show "$d" 2>/dev/null | grep -o 'mtu [0-9]*' | head -1 | cut -d' ' -f2)
  [ "$m" = 9000 ] || echo "[lutune] WARN $d mtu=${m}≠9000（netplan/mesh 域）"
done

[ "$fail" = 0 ] && echo "[lutune] 全 16 口 rx=${RX_TARGET} 复验 OK" || rc=1
exit $rc
