#!/bin/bash
# fabric-doctor.sh — 环网 doctor 面：HCA 端口 ACTIVE/接口在位/carrier 采样核查（只读诊断）
#
# 【为什么存在】TOOLS31-PACKAGE-PLAN §二 P1-3「doctor 面（HCA 端口 ACTIVE/接口在位核查）」
#   ——四症状鉴别法（COMMUNITY-FIELDNOTES 症状 2：端口 state=ACTIVE 而 carrier 假活跃，
#   须采样 /sys/class/net/<iface>/carrier 非 state 单读）的案头/host 只读承载件。
# 【零动作红线】本件**只读不修**：零 ip 命令写面、零 modprobe、零 sudo；红=报告+建议
#   （verdict JSON 出口），处置归 runbook/FABRIC-GID-REPAIR 正典序。
# 【mock 面】FABRIC_MOCK_SYS=/tmp/mock 根时读 mock 树（selfcheck 红绿双例用）；
#   缺省读真 /sys 与 /sys/class/infiniband（host 面允许律）。
# 【出口】人读横幅 + `--json` 时 verdict JSON 三字段族（_lib/verdict.sh）。
#   退出码：0=绿/1=红/2=无法判（判据面缺位=mock 外无 /sys 判据类）。
set -u
PKG_LIB="$(cd "$(dirname "$0")/../../.." && pwd)/_lib"
# shellcheck source=../../_lib/verdict.sh
[ -f "$PKG_LIB/verdict.sh" ] && . "$PKG_LIB/verdict.sh"

DEVLIST="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
HCAS="rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1"
SYS="${FABRIC_MOCK_SYS:-}"
CARRIER_SAMPLES="${FABRIC_CARRIER_SAMPLES:-3}"; CARRIER_SLEEP="${FABRIC_CARRIER_SLEEP_MS:-200}"

sys_path() { if [ -n "$SYS" ]; then echo "$SYS$1"; else echo "$1"; fi; }

[ "${1:-}" = "--json" ] && JSON=1 || JSON=0
vr_begin; vr_suggest "按 COMMUNITY-FIELDNOTES 症状表鉴别；处置走 FABRIC-GID-REPAIR-RUNBOOK 正典序" "fabric-net#runbook" manual

# ── 判据 1：接口在位（/sys/class/net/<iface> 存在）──
for d in $DEVLIST; do
  p="$(sys_path "/sys/class/net/$d")"
  if [ ! -d "$p" ]; then vr_face "iface-missing" "$d"; else echo "[doctor] iface $d 在位"; fi
done

# ── 判据 2：HCA 在位+端口 state=ACTIVE（/sys/class/infiniband/<hca>/ports/1/state）──
for h in $HCAS; do
  p="$(sys_path "/sys/class/infiniband/$h/ports/1/state")"
  if [ ! -r "$p" ]; then vr_unknown "hca-state-unreadable" "$h（判据面缺位）"; continue; fi
  st="$(cat "$p" 2>/dev/null)"
  case "$st" in
    *ACTIVE*) echo "[doctor] hca $h state=ACTIVE" ;;
    *)        vr_face "hca-not-active" "$h state=${st:-<空>}" ;;
  esac
done

# ── 判据 3：carrier 采样（ACTIVE 假活跃鉴别：N 发采样，任一 0=红面）──
for d in $DEVLIST; do
  p="$(sys_path "/sys/class/net/$d/carrier")"
  [ -r "$p" ] || { vr_unknown "carrier-unreadable" "$d"; continue; }
  zeros=0; reads=0
  for i in $(seq 1 "$CARRIER_SAMPLES"); do
    c="$(cat "$p" 2>/dev/null)"; reads=$((reads+1))
    [ "$c" = "0" ] && zeros=$((zeros+1))
    [ "$CARRIER_SLEEP" -gt 0 ] && sleep "$(awk -v x="$CARRIER_SLEEP" 'BEGIN{printf "%.3f", x/1000}')"
  done
  if [ "$reads" = 0 ]; then vr_unknown "carrier-noread" "$d"
  elif [ "$zeros" -gt 0 ]; then vr_face "carrier-flap" "$d ${zeros}/${reads} 发=0（症状2 签名：ACTIVE 假活跃）"
  else echo "[doctor] iface $d carrier ${CARRIER_SAMPLES}/${reads} 发全 1"; fi
done

echo "[doctor] 判读汇总见下（verdict=$([ -s "${VR_FACES_FILE:-/dev/null}" ] && echo 有红面 || echo 暂无))"
if [ "$JSON" = 1 ]; then vr_emit; fi
# 非 JSON 面也以同语义退出码收口
if   grep -qv '^UNKNOWN:' "$VR_FACES_FILE" 2>/dev/null && [ -s "$VR_FACES_FILE" ]; then exit 1
elif [ -s "$VR_FACES_FILE" ]; then exit 2
else exit 0; fi
