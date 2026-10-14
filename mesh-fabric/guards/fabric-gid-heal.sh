#!/bin/bash
# fabric-gid-heal.sh — GID idx3 洞瞬时自愈链（FABRIC-SELFHEAL-DESIGN-20261008 §二；裁定 G 落地件）
#
# 法源：用户裁定 G（2026-10-08）：线缆松动=瞬时性非持续故障 ⇒ 软件层配置自愈（环回重铺
# 毫秒级窗口），不影响长期运行稳定性；持续性通讯质量问题大声警告（→guard Q1-Q7 面）。
# 动作正典=runbook §2（~/w6-kit/FABRIC-GID-REPAIR-RUNBOOK.md md5 cc84ba86）IP 环回：
#   每洞口一次 ip addr del/add 同址（逼 rdma_cm 重铺紧凑 GID 表 v1@2/v2@3）。
# 法 A=sudo ip（复原窗 22:32Z 实证正典）；法 B=busybox 静态件借 docker --network host
#   --privileged（统一窗 15:52Z 实证备道）。单法单次，双法皆败=停手 CRIT。
#
# 触发：fabric-guard.sh F-G5 红路径调用（hole 形态）；亦可人工（本文件直接跑=只修本机洞口）。
# 四前置（P1-P4，全绿才动手；任一不满足=停手转告警，绝不盲目重试）：
#   P1 确定性洞：types/3≠RoCE v2 且 gids/3 空 + 链路 state=ACTIVE
#   P2 地址确定性：HCA→netdev 动态映射（gid_attrs/ndevs/2）后该口恰一条 IPv4 且=topology ports 期望
#   P3 本机无引擎：无 r3boot-*/r3prod-*/dsv41-* 容器（环回=瞬断 QP 面）
#   P4 频次未熔断：state heal.history 1h 内 <2 次（≥2=熔断，guard Q5 面）
# 安全边界（§2.3）：只碰 DEVLIST 四 fabric 口；enP7s7 管理口与 01 机 macgw /30 副地址
#   （192.168.0.2）永不在动作面（P2 的「恰一条 IPv4」断言天然排除宽接口形态）。
# 白名单硬界：HCA 名单四件固定；净覆盖=F06 语义（topology 期望表）。
set -u

DEVLIST="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
HCAS="rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1"
STATE=/opt/dsv41-mesh/state/fabric-guard.json
ALERTS=/opt/dsv41-mesh/fabric-alerts.log
ALERTS_DIR=/opt/dsv41-mesh/ALERTS
TOPOL=/opt/dsv41-mesh/topology.json
FUSE_RESET=/opt/dsv41-mesh/state/fabric-heal-fuse.reset

ts(){ date -u +%FT%TZ; }
hh(){ echo "[HEAL] $(ts) $(hostname) $*"; }
hh_log(){ hh "$*" | tee -a "$ALERTS"; logger -t fabric-guard -p daemon.notice "$(hh "$*")"; }
hh_crit(){ hh "$*" | tee -a "$ALERTS"; logger -t fabric-guard -p daemon.err "CRIT $(hh "$*")"; }

# ── 熔断态检查（P4 前半；复位律=人工触碰 state/fabric-heal-fuse.reset）──
if [ -f "$FUSE_RESET" ]; then
  python3 - "$STATE" "$FUSE_RESET" <<'PYEOF' 2>/dev/null
import json,os,sys,datetime
state,fr=sys.argv[1],sys.argv[2]
j=json.load(open(state)) if os.path.exists(state) else {}
h=j.get('heal',{})
# 人工复位律（D2.5 实测补全）：清 fuse 须同时归档 history——否则 P4 频次门仍用旧窗口拦截，
# 复位形同虚设。复位=操作员已人审，频次重新起算。
h['history_archived']=(h.get('history') or [])[-50:]
h['history']=[]
h['fuse']=False; h['fuse_ts']=None
j['heal']=h; json.dump(j,open(state,'w'),indent=2)
os.remove(fr)
PYEOF
  hh_log "熔断人工复位已执行（fabric-heal-fuse.reset 触碰律；history 归档+频次重新起算）——自愈面恢复"
fi
FUSED=$(python3 -c "import json,os;j=json.load(open('$STATE')) if os.path.exists('$STATE') else {};print(1 if j.get('heal',{}).get('fuse') else 0)" 2>/dev/null)

# ── 审计：本机哪些口是确定性洞（P1）──
declare -A HOLE_DEV HOLE_ADDR HOLE_HCA
n_holes=0; skipped=""
for hca in $HCAS; do
  ty=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/3 2>/dev/null)
  g=$(cat /sys/class/infiniband/$hca/ports/1/gids/3 2>/dev/null)
  st=$(cat /sys/class/infiniband/$hca/ports/1/state 2>/dev/null)
  if [ "$ty" = "RoCE v2" ] && [ -n "$g" ] && [ "$g" != "0000:0000:0000:0000:0000:0000:0000:0000" ]; then
    continue  # 该口健康
  fi
  # 洞或错值：只有「链路 ACTIVE + idx3 空」=确定性洞（自愈对象）；其余=停手形态
  if [ "$st" = "4: ACTIVE" ] && { [ -z "$g" ] || [ "$g" = "0000:0000:0000:0000:0000:0000:0000:0000" ]; }; then
    # P2：HCA→netdev 动态发现（runbook §2 勿背表）。洞形下 idx2 也空⇒ndevs/2 读 EINVAL
    # （D1 实测）——改经 topology gid3 期望 IP 在活口上的实际持有者定位（同为动态查，不背表）。
    exp_ip=$(python3 -c "import json;j=json.load(open('$TOPOL'));print(j['hosts'].get('$(hostname)',{}).get('gid3',{}).get('$hca',''))" 2>/dev/null)
    ndev=""
    for d in $DEVLIST; do
      if ip -o addr show dev "$d" 2>/dev/null | grep -q " inet ${exp_ip}/"; then ndev=$d; break; fi
    done
    if [ -z "$ndev" ]; then
      skipped="$skipped $hca(期望址 $exp_ip 无活口持有——映射异常)"; continue
    fi
    n_v4=$(ip -o addr show dev "$ndev" 2>/dev/null | grep -c ' inet ')
    addr_pfx=$(ip -o addr show dev "$ndev" 2>/dev/null | awk '/ inet /{print $4; exit}')
    exp_port_ip=$(python3 -c "import json;j=json.load(open('$TOPOL'));print(j['hosts'].get('$(hostname)',{}).get('ports',{}).get('$ndev',{}).get('ip',''))" 2>/dev/null)
    if [ "$n_v4" != "1" ] || [ -z "$addr_pfx" ] || [ "${addr_pfx%%/*}" != "$exp_ip" ] || [ "$exp_port_ip" != "$exp_ip" ]; then
      skipped="$skipped $hca(地址不确定: n_v4=$n_v4 addr=$addr_pfx gid3期=$exp_ip ports期=$exp_port_ip)"; continue
    fi
    HOLE_HCA[$n_holes]=$hca; HOLE_DEV[$n_holes]=$ndev; HOLE_ADDR[$n_holes]=$addr_pfx
    n_holes=$((n_holes+1))
  else
    skipped="$skipped $hca(非确定性洞形态: idx3=[$g] type=[$ty] state=[$st]——mismatch/链路down 只告警不自愈)"
  fi
done

if [ "$n_holes" = 0 ]; then
  [ -n "$skipped" ] && hh_log "无可自愈洞；非自愈形态（人审）：$skipped"
  exit 0
fi

# ── P3：本机无引擎（环回=瞬断 QP 面操作）──
CTNS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(r3boot|r3prod|dsv41)-' || true)
if [ "${CTNS:-0}" != "0" ]; then
  hh_crit "洞在但本机有引擎容器（n=$CTNS）——环回瞬断面禁做，等待态（P3 红不自愈）"
  exit 3
fi

# ── P4：自愈频次熔断（1h 内 ≥2 次=停一切自动动作至人工复位）──
if [ "$FUSED" = "1" ]; then
  hh_crit "熔断态在（heal.fuse=1）——本轮停手；人工复位=触碰 $FUSE_RESET 后下轮守卫自动解锁"
  exit 4
fi
N_1H=$(python3 - "$STATE" <<'PYEOF' 2>/dev/null
import json,os,sys,datetime
j=json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
now=datetime.datetime.utcnow()
n=0
for e in j.get('heal',{}).get('history',[]):
    try:
        if (now-datetime.datetime.strptime(e.get('ts',''),'%Y-%m-%dT%H:%M:%SZ')).total_seconds()<3600: n+=1
    except Exception: pass
print(n)
PYEOF
)
[ "${N_1H:-0}" -ge 2 ] && { hh_crit "自愈频次熔断：1h 内已 $N_1H 次（Q5）——疑似持续故障被自愈掩盖，停自动动作待人工复位"; exit 4; }

# ── 动作序（§2.2）：法 A=sudo ip 环回；不绿→法 B=busybox 容器备道；单法单次 ──
mkdir -p "$ALERTS_DIR"
heal_one(){  # <idx> <method>
  local i=$1 method=$2 hca dev addr rc=1
  hca=${HOLE_HCA[$i]}; dev=${HOLE_DEV[$i]}; addr=${HOLE_ADDR[$i]}
  if [ "$method" = A ]; then
    if [ "$(id -u)" = 0 ]; then
      ip addr del "$addr" dev "$dev" 2>/dev/null; ip addr add "$addr" dev "$dev" 2>/dev/null && rc=0
    else
      cat ~/.sudopw | sudo -S sh -c "ip addr del $addr dev $dev && ip addr add $addr dev $dev" >/dev/null 2>&1 && rc=0
    fi
  else  # 法 B：busybox 静态件借 host 网络特权容器（统一窗实证通道）
    docker run --rm --network host --privileged busybox sh -c "ip addr del $addr dev $dev && ip addr add $addr dev $dev" >/dev/null 2>&1 && rc=0
  fi
  echo $rc
}

RESULT=""
for ((i=0;i<n_holes;i++)); do
  hca=${HOLE_HCA[$i]}; dev=${HOLE_DEV[$i]}; addr=${HOLE_ADDR[$i]}
  hh_log "洞口 $hca（netdev=$dev addr=$addr）开始环回重铺（法 A=sudo ip）"
  rc=$(heal_one "$i" A)
  method=A
  if [ "$rc" != 0 ]; then
    hh_log "法 A 失败（rc=$rc）→法 B=busybox 特权容器备道（单法单次）"
    rc=$(heal_one "$i" B); method=B
  fi
  if [ "$rc" != 0 ]; then
    hh_crit "双法皆败：$hca（$dev $addr）环回不可做——停手；GID=2 整体切换预案=runbook §4（四机一致律，绝不单机）"
    RESULT="$RESULT
FAIL $hca 法$method 双法皆败"
    continue
  fi
  # ── Tier1 本机复验：sysfs 重读（types/3=RoCE v2+gids/3 非空+v4=期望+idx2 紧凑+ACTIVE）──
  sleep 2
  ty=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/3 2>/dev/null)
  g=$(cat /sys/class/infiniband/$hca/ports/1/gids/3 2>/dev/null)
  ty2=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/2 2>/dev/null)
  st=$(cat /sys/class/infiniband/$hca/ports/1/state 2>/dev/null)
  v4=$(python3 - "$g" <<'PYT' 2>/dev/null
import socket,sys
try:
    b=bytes.fromhex(sys.argv[1].strip().replace(':',''))
    print(socket.inet_ntop(socket.AF_INET,b[12:16]) if len(b)==16 else '')
except Exception: print('')
PYT
)
  exp1=$(python3 -c "import json;j=json.load(open('$TOPOL'));print(j['hosts'].get('$(hostname)',{}).get('gid3',{}).get('$hca',''))" 2>/dev/null)
  if [ "$ty" = "RoCE v2" ] && [ -n "$g" ] && [ "$g" != "0000:0000:0000:0000:0000:0000:0000:0000" ] && [ "$v4" = "$exp1" ] && [[ "$ty2" == *v1 ]] && [ "$st" = "4: ACTIVE" ]; then
    hh_log "HEALED $hca 环回重铺 OK（法 $method）+Tier1 复验绿（idx3=$v4 idx2=v1 紧凑）"
    RESULT="$RESULT
OK $hca 法$method"
  else
    hh_crit "修复不绿：$hca idx3=[$g] v4=[$v4] type=[$ty] idx2type=[$ty2] state=[$st]（法 $method 后）——计熔断频次，下轮最多再试一次；runbook §4=四机整体切 GID=2 预案人审"
    RESULT="$RESULT
FAIL $hca 法$method idx3-not-green"
  fi
done

# ── state 留痕（heal.history 环形 50 条；Q5 消费面）──
python3 - "$STATE" "$RESULT" <<'PYEOF'
import json,os,sys,datetime
state,result=sys.argv[1],sys.argv[2]
j=json.load(open(state)) if os.path.exists(state) else {}
h=j.get('heal',{})
hist=h.get('history',[])
for tok in result.splitlines():
    if not tok.strip(): continue
    parts=tok.split()
    hist.append({"ts":datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                 "port":parts[1] if len(parts)>1 else '?',
                 "method":parts[2] if len(parts)>2 else '?',
                 "result":parts[0]})
n1h=sum(1 for e in hist if (datetime.datetime.utcnow()-datetime.datetime.strptime(e['ts'],'%Y-%m-%dT%H:%M:%SZ')).total_seconds()<3600)
h['history']=hist[-50:]; h['last_heal_ts']=hist[-1]['ts'] if hist else None
if n1h>=2: h['fuse']=True; h['fuse_ts']=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
j['heal']=h
os.makedirs(os.path.dirname(state),exist_ok=True)
json.dump(j,open(state,'w'),indent=2)
PYEOF
exit 0
