#!/bin/bash
# fabric-restore-gate.sh — 引擎二阶段自愈门 Phase1（FABRIC-SELFHEAL-DESIGN-20261008 §四）
#
# 语义：01 机执行（非 01 hostname 直接 exit 0；四机部署保 guards md5 对齐）。
# 由 fabric-guard.sh 尾部调用（5min 周期复用，零新 timer 面）。
# Phase1（首部署档，设计卡 §4.2 推荐）：五判据全绿 ⇒ CRIT 级「ENGINE-DEAD-READY-TO-BOOT」
#   三通道广播（journal+alerts 文件+ALERTS flag）——人/操作员执行 slotlock bump boot。
#   **不自动点火**（晋档判据：演练三注入全绿+首个真实单翻转事件端到端绿+14 天零误报，另呈裁）。
#
# 五触发判据（§4.1，全绿才广播；任一红=安静退出留 state 注记）：
#   J1 8899 死（health 非 200/连接拒）且四机 docker ps 无 r3boot/r3prod 容器（引擎确死集群级）
#   J2 GID 零洞：四机 16 口 idx3=RoCE v2 非空（四机 sysfs ssh 汇读；洞在=先 heal 链，本 Gate 等待）
#   J3 链路 ACTIVE 静默 ≥5min：本机 flap.events 最近事件距 now ≥5min 且四口全 ACTIVE
#   J4 Tier2 verify 绿：s4_bench verify 的 GID 预检部分（四机 16 口零洞=fail-closed 面；
#      OpenMPI wireup 部分与 01 机 macgw /30 副地址结构性冲突=量具面呈裁件，如实注记不阻塞）
#   J5 熔断未触发（heal.fuse）且 Q1 非 CRIT-STANDING（持续性翻转态=只告警不广播）
#
# 排除面重申：不触碰 02 机 oom-gate-monitor/r3-watchdog-worker；不复用 w6-kit watchdog 单元。
# U1 差异面：先绿后起（本 Phase1 只广播不起）；槽治理=广播文案强制 wrapper 路径。
set -u

[ "$(hostname)" = "dgxspark01" ] || exit 0

HOSTS="dgxspark01 dgxspark02 dgxspark03 dgxspark04"
DEVLIST="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
HCAS="rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1"
STATE=/opt/dsv41-mesh/state/fabric-guard.json
ALERTS=/opt/dsv41-mesh/fabric-alerts.log
ALERTS_DIR=/opt/dsv41-mesh/ALERTS
# ssh 包装：systemd/root 语境无用户密钥（2026-10-09 部署窗实测 root ssh 空→容器数 99×4 假红）；
# root 下经 sudo -u liux***ya 走用户密钥面。
if [ "$(id -u)" = 0 ]; then
  SSH="sudo -u liux***ya ssh -o BatchMode=yes -o ConnectTimeout=8"
else
  SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
fi
GATE_STATE=/opt/dsv41-mesh/state/fabric-restore-gate.json

ts(){ date -u +%FT%TZ; }

# ── J1：8899 死 + 四机引擎容器净 ──
p9=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8899/health 2>/dev/null); p9=${p9:-000}
ctn_total=0
for h in $HOSTS; do
  if [ "$h" = "dgxspark01" ]; then n=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(r3boot|r3prod)-' || true)
  else n=$($SSH "$h" "docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(r3boot|r3prod)-'" 2>/dev/null); fi
  [[ "${n:-?}" =~ ^[0-9]+$ ]] || n=99
  ctn_total=$((ctn_total+n))
done
J1=$([ "$p9" != "200" ] && [ "$ctn_total" = "0" ] && echo 1 || echo 0)

# ── J2：四机 GID 零洞（16 口 idx3=RoCE v2）──
holes=""
for h in $HOSTS; do
  if [ "$h" = "dgxspark01" ]; then out=$(for c in $HCAS; do ty=$(cat /sys/class/infiniband/$c/ports/1/gid_attrs/types/3 2>/dev/null); g=$(cat /sys/class/infiniband/$c/ports/1/gids/3 2>/dev/null); { [ "$ty" = "RoCE v2" ] && [ -n "$g" ] && [ "$g" != 0000:0000:0000:0000:0000:0000:0000:0000 ]; } || echo "$h:$c"; done)
  else out=$($SSH "$h" 'for c in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do ty=$(cat /sys/class/infiniband/$c/ports/1/gid_attrs/types/3 2>/dev/null); g=$(cat /sys/class/infiniband/$c/ports/1/gids/3 2>/dev/null); { [ "$ty" = "RoCE v2" ] && [ -n "$g" ] && [ "$g" != 0000:0000:0000:0000:0000:0000:0000:0000 ]; } || echo "'$h':$c"; done' 2>/dev/null); fi
  holes="$holes$(echo "$out" | grep -v '^$' | tr '\n' ' ')"
done
J2=$([ -z "$holes" ] && echo 1 || echo 0)

# ── J3：本机链路 ACTIVE 静默 ≥5min（flap.events 尾事件+四口 operstate）──
last_evt=$(python3 -c "import json,os;j=json.load(open('$STATE')) if os.path.exists('$STATE') else {};e=j.get('flap',{}).get('events',[]);print(e[-1]['ts_epoch'] if e else 0)" 2>/dev/null)
now=$(date +%s); quiet=$(( now - ${last_evt:-0} ))
links_ok=1
for d in $DEVLIST; do [ "$(cat /sys/class/net/$d/operstate 2>/dev/null)" = "up" ] || links_ok=0; done
J3=$([ "$quiet" -ge 300 ] && [ "$links_ok" = 1 ] && echo 1 || echo 0)

# ── J4：Tier2 verify 绿（GID 预检面=J2 同源四机汇读复用；OpenMPI 部分量具冲突注记）──
# 注：s4_bench verify 完整面（mpirun wireup）与 01 机 macgw /30 副地址结构性冲突（复原窗定谳
# 呈裁件）；本 Gate 的 Tier2=s4_bench verify 自带 GID 预检同判据（exit 9 家族 fail-closed），
# 即上方 J2 的四机 16 口汇读。副证=perftest 矩阵（人工窗实录 8/8 OK 25.3GB/s 直证 idx3 路径）。
J4=$J2

# ── J5：熔断未触发 + Q1 非 CRIT-STANDING ──
fused=$(python3 -c "import json,os;j=json.load(open('$STATE')) if os.path.exists('$STATE') else {};print(1 if j.get('heal',{}).get('fuse') else 0)" 2>/dev/null)
q1_standing=$([ -f "$ALERTS_DIR/CRIT-STANDING-Q1-flap-rate" ] && echo 1 || echo 0)
J5=$([ "${fused:-0}" = "0" ] && [ "$q1_standing" = "0" ] && echo 1 || echo 0)

verdict=$(( J1 & J2 & J3 & J4 & J5 ))

# ── state 注记（人读+晋档数据积累）──
mkdir -p /opt/dsv41-mesh/state
python3 - "$GATE_STATE" "$J1" "$J2" "$J3" "$J4" "$J5" "$verdict" "$p9" "$ctn_total" "$holes" <<'PYEOF'
import json,os,sys,datetime
g=sys.argv[1]; J=sys.argv[2:8]; p9,ctn,holes=sys.argv[8],sys.argv[9],sys.argv[10]
j={"last_run":datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
   "phase":1,
   "judgements":{"J1_engine_dead_and_clean":int(J[0]),"J2_gid_zero_hole":int(J[1]),
                  "J3_link_quiet_5min":int(J[2]),"J4_tier2_gid_precheck":int(J[3]),
                  "J5_no_fuse_no_q1standing":int(J[4])},
   "verdict":int(J[5]),"health_8899":p9,"engines_ctn_total":int(ctn),
   "gid_holes":holes.split(),
   "tier2_note":"GID 预检面（s4_bench verify fail-closed 同判据）；OpenMPI wireup 部分与 01 机 macgw /30 副地址结构性冲突=呈裁件不阻塞"}
json.dump(j,open(g,'w'),indent=2)
PYEOF

if [ "$verdict" = "1" ]; then
  mkdir -p "$ALERTS_DIR"
  if [ "${last_evt:-0}" = "0" ]; then quiet_disp="∞（零事件在档）"; else quiet_disp="${quiet}s"; fi
  MSG="ENGINE-DEAD-READY-TO-BOOT：五判据全绿（8899=$p9/容器净/GID 零洞/链路静默$quiet_disp/无熔断无Q1驻留）——请操作员执行：ARM_TAG=FABRIC-RESTORE-$(date -u +%Y%m%dT%H%M%SZ) CTN_PREFIX=r3prod API_PORT=8899 SPEC=1 ARM_ENV_FILE=~/migrate-assets/dsv41/env/PROD-R1STDCERT-spec1.env bash ~/luz030-opt-campaign/tools/boot-with-slotlock.sh bash ~/migrate-assets/bin/r3-boot-arm.sh（Phase1 只广播不自动点火；槽锁纪律强制走 wrapper）"
  echo "[$(ts)] CRIT $MSG" >> "$ALERTS"
  logger -t fabric-guard -p daemon.err "CRIT $MSG"
  echo "[$(ts)] CRIT $MSG" > "$ALERTS_DIR/CRIT-READY-TO-BOOT-$(date -u +%Y%m%dT%H%M%SZ).flag"
  echo "[restore-gate] $(ts) READY-TO-BOOT 广播三通道落痕（Phase1）"
fi
exit 0
