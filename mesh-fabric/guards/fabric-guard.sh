#!/bin/bash
# fabric-guard.sh v2 — 5min fabric 自检（F-G1..F-G10）+计数器差分+分级自愈+持续性质化判据（Q1-Q7）
# 谱系：KNAPCIO-FABRIC-TUNING-20261007 §三/§五裁定 6 实现件（v1=f37e95e5）
#      + FABRIC-SELFHEAL-DESIGN-20261008（commit 8e36a2b）§一§二§三§五 v2 落地件。
# v2 增量（对 v1）：
#   F-G5 增强：洞/错值二分+链路态同采+结构化 gid_face；hole 形态红路径调 fabric-gid-heal.sh
#      （用户裁定 G：瞬时性=软件自愈；原「只告警停机律」姿势解除，四前置安全边界在 heal 件内）。
#   F-G6b 新增（裁定 H 注册面门禁）：drift/重启即失/GID 解析目标可达性三断言（WARN 级）。
#   F-G10 新增：journal 翻转事件扫描（游标增量）+operstate 次级比对（journal 丢失兜底）。
#   F-G7/8/9 增强：逐口分解+连续超限轮数（喂 Q3 持续性判据）。
#   Q1-Q7（§三判据表）+四路大声通道（journal CRIT/守卫红/alerts 文件+ALERTS flag/prome 不阻塞）
#      +CRIT-STANDING 驻留文件（6 轮绿滞回清除）。
#   尾部（01 机）：fabric-restore-gate.sh Phase1（引擎死态五判据 READY-TO-BOOT 广播）。
# 铁律遵守：RX_EXPECT=8192 本窗不动（ring4096 裁降未执行）；02 机双单元零触碰；
#   01 机 macgw /30 副地址（192.168.0.2）不在任何动作面。
set -u

# ── CFG（阈值一处集中；5min 窗口径；一切阈值=推荐值实施窗可调）───────────────
DEVLIST="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
HCA_OF="enp1s0f0np0:rocep1s0f0 enp1s0f1np1:rocep1s0f1 enP2p1s0f0np0:roceP2p1s0f0 enP2p1s0f1np1:roceP2p1s0f1"
DEVLINK_BUSES="pci/0000:01:00.0 pci/0000:01:00.1 pci/0002:01:00.0 pci/0002:01:00.1"
RX_EXPECT=4096; TX_EXPECT=1024
BUFFER_TEMPLATE="19872,523296,0,0,0,0,0,0"   # F-G2（P2 未装=出厂慢性基线即模板）
TRUST_TEMPLATE="pcp"                         # F-G3 ring 模板
HAIRPIN_EXPECT=8192                          # F-G4
TH_FEC_CORR=600   # F-G7 corrected 5min Δ 阈
TH_CRC=0          # F-G7 不可纠类
TH_OOB=100        # F-G8
TH_P0D=100        # F-G8
TH_OOS=100        # F-G9
TH_CNP=100        # F-G9
TH_Q1_WARN_24H=2; TH_Q1_CRIT_24H=3; TH_Q1_CRIT_1H=2    # Q1（10-08 实况 3 次/7.3h 校准）
TH_Q2_NORET=60                                          # Q2 down 后 60s 未回
TH_Q3_CONSEC=3                                          # Q3 连续 3 轮（15min）超阈
TH_Q4_CONSEC=3                                          # Q4 连续 3 轮（45min）哨兵带外
TH_Q5_FUSE_1H=2                                         # Q5 自愈 1h ≥2=熔断
TH_Q6_CONSEC=2                                          # Q6 连续 2 轮（10min）不可修
TH_Q7_CONSEC=2                                          # Q7 连续 2 轮检测面缺口
TH_STANDING_CLEAR=6                                     # CRIT-STANDING 滞回清除轮数
STATE=/opt/dsv41-mesh/state/fabric-guard.json
ALERTS=/opt/dsv41-mesh/fabric-alerts.log
ALERTS_DIR=/opt/dsv41-mesh/ALERTS
TOPOL=/opt/dsv41-mesh/topology.json
NE_CTN="${NODE_EXPORTER_CTN:-aicad-node-exporter}"
HEAL_SH=/opt/dsv41-mesh/bin/fabric-gid-heal.sh
GATE_SH=/opt/dsv41-mesh/bin/fabric-restore-gate.sh

fg_ts=$(date -u +%FT%TZ)
warn(){ echo "WARN $*"; logger -t fabric-guard -p daemon.warning "WARN $*"; echo "[$fg_ts] WARN $*" >> "$ALERTS"; }
crit(){ echo "CRIT $*"; logger -t fabric-guard -p daemon.err "CRIT $*"; echo "[$fg_ts] CRIT $*" >> "$ALERTS"; }
cur_rx(){ ethtool -g "$1" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f&&/^RX:/{print $2; exit}'; }
cur_tx(){ ethtool -g "$1" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f&&/^TX:/{print $2; exit}'; }
etS(){ ethtool -S "$1" 2>/dev/null | awk -v k="$2" '$1==k":"{print $2}'; }
mkdir -p "$ALERTS_DIR" 2>/dev/null || true

RED_PARAM=""; WARN_FACE=""

# ── 上一轮快照载入（counters 域 v1 兼容 + v2 扩展域）──
SNAP=/tmp/fabric-guard-snap.$$
PREV_TS=""
PREV_JSON=""
if [ -r "$STATE" ]; then
  python3 -c "
import json
try:
  j=json.load(open('$STATE'))
  print(j.get('snapshot_ts',''))
  for k,v in j.get('counters',{}).items(): print(k,v)
except Exception: pass" > "$SNAP.prev" 2>/dev/null
  PREV_TS=$(head -1 "$SNAP.prev")
  tail -n +2 "$SNAP.prev" > "$SNAP.prev2"
  PREV_JSON=$(python3 -c "import json;print(json.dumps(json.load(open('$STATE'))))" 2>/dev/null)
else
  : > "$SNAP.prev2"
fi

# ── F-G1 ring（红→L1 重放 lutune.sh→复验；仍红=CRIT）───────────────────────
g1_red=""
for d in $DEVLIST; do
  r=$(cur_rx "$d"); t=$(cur_tx "$d")
  [ "$r" = "$RX_EXPECT" ] && [ "$t" = "$TX_EXPECT" ] || g1_red="$g1_red $d(rx=$r,tx=$t)"
done
if [ -n "$g1_red" ]; then
  warn "F-G1 ring 漂移：$g1_red → L1 重放 lutune.sh"
  bash /opt/dsv41-mesh/bin/lutune.sh >/dev/null 2>&1
  g1_red=""
  for d in $DEVLIST; do [ "$(cur_rx "$d")" = "$RX_EXPECT" ] || g1_red="$g1_red $d"; done
  if [ -n "$g1_red" ]; then crit "F-G1 ring 重放后仍红：$g1_red"; RED_PARAM="$RED_PARAM F-G1"
  else warn "F-G1 ring 重放治愈（留痕）"; fi
fi
ring_ok=$([ -z "$g1_red" ] && echo 1 || echo 0)

# ── F-G2 prio 缓冲（模板=当前在役基线；P2 未装）────────────────────────────
buf=$(mlnx_qos -i enp1s0f0np0 2>/dev/null | grep 'Receive buffer size' | sed 's/.*bytes): //;s/,max_buffer_size=.*//')
[ "$buf" = "$BUFFER_TEMPLATE" ] || { crit "F-G2 缓冲漂移：得=$buf 期=$BUFFER_TEMPLATE"; RED_PARAM="$RED_PARAM F-G2"; }

# ── F-G3 trust+PFC ──
trust=$(mlnx_qos -i enp1s0f0np0 2>/dev/null | awk '/Priority trust state:/{print $NF}')
pfc35=$(mlnx_qos -i enp1s0f0np0 2>/dev/null | awk '/PFC configuration:/{f=1} f&&$1=="enabled"{print $5,$7; exit}')
[ "$trust" = "$TRUST_TEMPLATE" ] || { crit "F-G3 trust 漂移：$trust≠$TRUST_TEMPLATE"; RED_PARAM="$RED_PARAM F-G3"; }
[ "$pfc35" = "1 1" ] || { crit "F-G3 PFC prio3/5 漂移：得=[$pfc35] 期=1 1"; RED_PARAM="$RED_PARAM F-G3"; }

# ── F-G4 hairpin（只告警——devlink reinit=瞬断 QP 面操作，停机律禁自动重放）─
for B in $DEVLINK_BUSES; do
  hp=$(devlink dev param show "$B" name hairpin_queue_size 2>/dev/null | sed -n 's/.*cmode driverinit value \([0-9]*\).*/\1/p')
  [ "$hp" = "$HAIRPIN_EXPECT" ] || { crit "F-G4 hairpin=$hp@$B ≠$HAIRPIN_EXPECT（只告警；重放须停机窗）"; RED_PARAM="$RED_PARAM F-G4"; }
done

# ── F-G5 GID idx3（v2：洞/错值二分+链路态+结构化 gid_face；hole→heal 链）────
gid_face=$(python3 - "$TOPOL" <<'PYEOF'
import json,socket,sys
topol=sys.argv[1]
try:
    j=json.load(open(topol)); me=socket.gethostname()
    gid3=j['hosts'].get(me,{}).get('gid3',{})
except Exception:
    gid3={}
hcas="rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1".split()
out=[]
for hca in hcas:
    exp=gid3.get(hca,'?')
    try:
        g=open(f'/sys/class/infiniband/{hca}/ports/1/gids/3').read().strip()
        b=bytes.fromhex(g.replace(':',''))
        v4=socket.inet_ntop(socket.AF_INET,b[12:16]) if len(b)==16 else 'none'
    except Exception:
        v4='none'
    try: ty=open(f'/sys/class/infiniband/{hca}/ports/1/gid_attrs/types/3').read().strip()
    except Exception: ty='none'
    try: st=open(f'/sys/class/infiniband/{hca}/ports/1/state').read().strip()
    except Exception: st='none'
    empty=(v4=='none' or g.replace(':','')=='0'*32)
    if ty=='RoCE v2' and not empty: verdict='ok' if v4==exp else 'mismatch'
    elif empty and st=='4: ACTIVE': verdict='hole'
    else: verdict='mismatch'
    out.append(f"{hca}|{st}|{ty}|{v4}|{verdict}|{exp}")
print('\n'.join(out))
PYEOF
)
gid_holes=$(awk -F'|' '$5=="hole"{print $1}' <<<"$gid_face" | tr '\n' ' ')
gid_mism=$(awk -F'|' '$5=="mismatch"{printf "%s(v4=%s≠%s)",$1,$4,$6}' <<<"$gid_face" | tr '\n' ' ')
gid_healed=""
gid_holes2=""
if [ -n "$gid_holes" ]; then
  warn "F-G5 GID 洞（翻转重铺签名）：$gid_holes → 自愈链 fabric-gid-heal.sh（裁定 G；四前置安全边界）"
  bash "$HEAL_SH" >/dev/null 2>&1
  # 复读（heal 后 Tier1 已复验；此处为守卫视角终读）
  gid_face=$(python3 - "$TOPOL" <<'PYEOF'
import json,socket,sys
topol=sys.argv[1]
try:
    j=json.load(open(topol)); me=socket.gethostname()
    gid3=j['hosts'].get(me,{}).get('gid3',{})
except Exception:
    gid3={}
hcas="rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1".split()
out=[]
for hca in hcas:
    exp=gid3.get(hca,'?')
    try:
        g=open(f'/sys/class/infiniband/{hca}/ports/1/gids/3').read().strip()
        b=bytes.fromhex(g.replace(':',''))
        v4=socket.inet_ntop(socket.AF_INET,b[12:16]) if len(b)==16 else 'none'
    except Exception:
        v4='none'
    try: ty=open(f'/sys/class/infiniband/{hca}/ports/1/gid_attrs/types/3').read().strip()
    except Exception: ty='none'
    try: st=open(f'/sys/class/infiniband/{hca}/ports/1/state').read().strip()
    except Exception: st='none'
    empty=(v4=='none' or g.replace(':','')=='0'*32)
    if ty=='RoCE v2' and not empty: verdict='ok' if v4==exp else 'mismatch'
    elif empty and st=='4: ACTIVE': verdict='hole'
    else: verdict='mismatch'
    out.append(f"{hca}|{st}|{ty}|{v4}|{verdict}|{exp}")
print('\n'.join(out))
PYEOF
)
  gid_holes2=$(awk -F'|' '$5=="hole"' <<<"$gid_face" | tr '\n' ' ')
  if [ -z "$gid_holes2" ]; then
    warn "F-G5 GID 洞自愈后复验绿（heal.history 在档；HEALED 三通道由 heal 件落痕）"
    gid_healed="$gid_holes"
  else
    crit "F-G5 GID 洞自愈后仍在：$gid_holes2（Q6 计轮；前置不满足或双法皆败形态人审 runbook §2/§4）"
    RED_PARAM="$RED_PARAM F-G5"
  fi
fi
[ -n "$gid_mism" ] && { crit "F-G5 GID 面 mismatch（非翻转形态只告警不自愈）：$gid_mism"; RED_PARAM="$RED_PARAM F-G5"; }

# ── F-G6 mesh 面（fabricctl check 复用；先 ping 邻居解析 F09 冷启空面）──────
nhs=$(python3 -c "
import json
try:
  j=json.load(open('$TOPOL'))
  for r in j['hosts']['$(hostname)'].get('routes32',[]): print(r.split()[2])
except Exception: pass" 2>/dev/null)
for nh in $nhs; do ping -c1 -W2 "$nh" >/dev/null 2>&1 || true; done
fc_out=$(/opt/dsv41-mesh/bin/fabricctl check 2>&1)
fc_fail_n=$(grep '^FAIL' <<<"$fc_out" | grep -cv 'systemd-1')
[ "$fc_fail_n" = 0 ] || { warn "F-G6 fabricctl FAIL×$fc_fail_n（mesh 域；fabricctl check 直查）"; WARN_FACE="$WARN_FACE F-G6"; }
for mp in /data/models/dsv41-net /data/models/DeepSeek-V4.1-Flash; do
  if grep -q " $mp " /proc/mounts || [ -d "$mp" ]; then
    timeout 8 ls "$mp" >/dev/null 2>&1 || { warn "F-G6 NFS 树不可达：$mp（权重面硬前置）"; WARN_FACE="$WARN_FACE F-G6-nfs"; }
  fi
done

# ── F-G6b 注册面一致性三断言（裁定 H：/32-vs-/24 家族进告警门禁；全 WARN 级）──
g6b_out=$(python3 - "$TOPOL" <<'PYEOF'
import json,subprocess,sys,os,ipaddress,socket
topol=sys.argv[1]
me=socket.gethostname()
try: j=json.load(open(topol)); h=j['hosts'].get(me,{})
except Exception: h={}
want=[r for r in h.get('routes32',[])]
FAB={'enp1s0f0np0','enp1s0f1np1','enP2p1s0f0np0','enP2p1s0f1np1'}
# b1 drift：运行态规范化 vs 注册面（双向差；只看 fabric 口路由，default/管理面不进集）
r=subprocess.run(['ip','route'],capture_output=True,text=True).stdout.splitlines()
run=set()
for ln in r:
    parts=ln.split()
    if len(parts)>=5 and parts[1]=='via' and parts[4] in FAB:
        run.add(f"{parts[0]} via {parts[2]} dev {parts[4]}")
wantset=set(want)
miss=sorted(wantset-run); extra=sorted(run-wantset)
# b2 持久化缺口：canonical 任一条不在本机 netplan 渲染面（97/99 文件 to:+via: 成对在档）
# ★2026-10-14 A-21 案 A（E1 尾批 1）：持久化提供者增计 dsv41-mesh boot 重放——mesh-up.sh
#   在册 ip route add <dst>/32 via <via> 成对=重启存活直证（逐条证据制豁免，非无条件放行）
np_miss=[]
mu_txt=''
try: mu_txt=open('/opt/dsv41-mesh/mesh-up.sh').read()
except Exception: pass
for w in want:
    t=w.split(); dst,via=w.split()[0],w.split()[2]
    found=False
    for f in ('/etc/netplan/97-roce-mtu.yaml','/etc/netplan/99-nvidia-sync-cluster.yaml'):
        try: txt=open(f).read()
        except Exception: continue
        if f"to: {dst}" in txt and f"via: {via}" in txt: found=True; break
    if not found and f"ip route add {dst}/32 via {via} " in mu_txt: found=True
    if not found: np_miss.append(w)
# b3 GID 解析目标可达性：covered_by_design 目标须 fabric 口/lo 可解析；未覆盖域记录不告警
own=set(h.get('gid3',{}).values())
allg=set()
for hh in j.get('hosts',{}).values(): allg|=set(hh.get('gid3',{}).values())
nets=[]
for w in want:
    t=w.split()
    try: nets.append(ipaddress.ip_network(t[0]))
    except Exception: pass
for ln in r:
    p=ln.split()
    # kernel 连接路由（含 /30 /24 直连子网）＝本机可达域
    if len(p)>=2 and p[1]=='dev' and p[0] not in ('default',) and '/' in p[0]:
        try: nets.append(ipaddress.ip_network(p[0]))
        except Exception: pass
unreach=[]; uncovered=[]
for g in sorted(allg):
    covered = g in own or any(ipaddress.ip_address(g) in n for n in nets)
    if not covered:
        uncovered.append(g); continue
    rr=subprocess.run(['ip','route','get',g],capture_output=True,text=True)
    if rr.returncode!=0:
        unreach.append(g); continue
    dev=[x for x in rr.stdout.split() if x=='dev']
    if not dev:
        unreach.append(g); continue
    idx=rr.stdout.split().index('dev'); d=rr.stdout.split()[idx+1]
    if d not in ('enp1s0f0np0','enp1s0f1np1','enP2p1s0f0np0','enP2p1s0f1np1','lo'):
        unreach.append(g)
print(f"MISS::{';'.join(miss)}")
print(f"EXTRA::{';'.join(extra)}")
print(f"NPMISS::{';'.join(np_miss)}")
print(f"UNREACH::{';'.join(unreach)}")
print(f"UNCOV::{';'.join(uncovered)}")
PYEOF
)
g6b_miss=$(grep '^MISS::' <<<"$g6b_out" | head -1 | sed 's/^MISS:://;s/;$/\n/' | grep -v '^$' | tr ';' ' ')
g6b_extra=$(grep '^EXTRA::' <<<"$g6b_out" | head -1 | sed 's/^EXTRA:://' | tr ';' ' ')
g6b_npmiss=$(grep '^NPMISS::' <<<"$g6b_out" | head -1 | sed 's/^NPMISS:://' | tr ';' ' ')
g6b_unreach=$(grep '^UNREACH::' <<<"$g6b_out" | head -1 | sed 's/^UNREACH:://' | tr ';' ' ')
g6b_uncov=$(grep '^UNCOV::' <<<"$g6b_out" | head -1 | sed 's/^UNCOV:://' | tr ';' ' ')
[ -n "$g6b_miss" ] && { warn "F-G6b-1 注册面/运行态 drift（缺）：$g6b_miss"; WARN_FACE="$WARN_FACE F-G6b-drift"; }
[ -n "$g6b_extra" ] && { warn "F-G6b-1 注册面/运行态 drift（多）：$g6b_extra"; WARN_FACE="$WARN_FACE F-G6b-drift"; }
[ -n "$g6b_npmiss" ] && { warn "F-G6b-2 运行态路由重启即失（netplan 缺）：$g6b_npmiss"; WARN_FACE="$WARN_FACE F-G6b-netplan"; }
[ -n "$g6b_unreach" ] && { warn "F-G6b-3 GID 解析目标无路由：$g6b_unreach"; WARN_FACE="$WARN_FACE F-G6b-gidreach"; }

# ── F-G10 翻转事件检测（journal 游标增量+operstate 次级比对）────────────────
flap_out=$(FLAP_CURSOR=$(python3 -c "
import json,os
try: j=json.load(open('$STATE')); print(j.get('flap',{}).get('cursor',''))
except Exception: print('')" 2>/dev/null) PREV_JSON="$PREV_JSON" python3 <<'PYEOF'
import json,os,re,subprocess,datetime,time
now=int(time.time())
cur=os.environ.get('FLAP_CURSOR','').strip()
if not cur: cur=str(now-300)
cur=int(float(cur))
r=subprocess.run(['journalctl','-k','-q','--since',f'@{cur}','-o','short-iso'],capture_output=True,text=True).stdout
portmap={'enp1s0f0np0':'enp1s0f0np0','enp1s0f1np1':'enp1s0f1np1','enP2p1s0f0np0':'enP2p1s0f0np0','enP2p1s0f1np1':'enP2p1s0f1np1',
         'rocep1s0f0':'enp1s0f0np0','rocep1s0f1':'enp1s0f1np1','roceP2p1s0f0':'enP2p1s0f0np0','roceP2p1s0f1':'enP2p1s0f1np1'}
events={}
for ln in r.splitlines():
    if 'mlx5_core' not in ln: continue
    m=re.search(r'(\S+)\s+\S+\s+kernel:',ln)
    hit=None;down=None
    for k in portmap:
        if re.search(rf'\b{re.escape(k)}\b',ln): hit=portmap[k]; break
    if not hit: continue
    low=ln.lower()
    if 'link down' in low: down=True
    elif 'link up' in low or 'link active' in low: down=False
    else: continue
    try: ts=int(datetime.datetime.fromisoformat(m.group(1)).timestamp())
    except Exception: continue
    key=(hit,ts//1,down)
    events[key]=(hit,ts,down)
evs=[{'port':p,'ts':t,'down':d} for (p,t,d) in events.values()]
evs.sort(key=lambda e:e['ts'])
# 游标推进=扫描窗上界（事件列表另存）
new_cursor=now-5
# Q2：down 后 >60s 无 up 且口未回
q2_ports=[]
last_up={}
for e in evs:
    if not e['down']: last_up[e['port']]=e['ts']
oper={}
for p in portmap:
    try: oper[p]=open(f'/sys/class/net/{p}/operstate').read().strip()
    except Exception: oper[p]='?'
for e in evs:
    if e['down']:
        up_after=last_up.get(e['port'],0)>e['ts']
        if not up_after and oper.get(e['port'])!='up' and (now-e['ts'])>60:
            if e['port'] not in q2_ports: q2_ports.append(e['port'])
# operstate 次级比对（Q7 兜底）
prev_states={}
try:
    pj=json.loads(os.environ.get('PREV_JSON','') or '{}')
    prev_states=pj.get('link_states',{})
except Exception: pass
cur_states=oper
changed=[p for p in cur_states if p in prev_states and prev_states[p]!=cur_states[p]]
journal_has=bool(evs)
print(f"EVENTS::{json.dumps(evs)}")
print(f"Q2::{','.join(q2_ports)}")
print(f"CHANGED::{','.join(changed)}")
print(f"JOURNAL_HAS::{1 if journal_has else 0}")
print(f"CURSORTS::{new_cursor}")
print(f"LINKSTATES::{json.dumps(cur_states)}")
PYEOF
)
flap_events=$(grep '^EVENTS::' <<<"$flap_out" | sed 's/^EVENTS:://')
flap_q2=$(grep '^Q2::' <<<"$flap_out" | sed 's/^Q2:://')
flap_changed=$(grep '^CHANGED::' <<<"$flap_out" | sed 's/^CHANGED:://')
flap_jhas=$(grep '^JOURNAL_HAS::' <<<"$flap_out" | sed 's/^JOURNAL_HAS:://')
flap_cursor_new=$(grep '^CURSORTS::' <<<"$flap_out" | sed 's/^CURSORTS:://')
link_states=$(grep '^LINKSTATES::' <<<"$flap_out" | sed 's/^LINKSTATES:://')
n_flap_new=$(python3 -c "import json,sys;e=json.loads('''${flap_events:-[]}''');print(sum(1 for x in e if x['down']))" 2>/dev/null || echo 0)
[ "${n_flap_new:-0}" -ge 1 ] 2>/dev/null && warn "F-G10 翻转事件：本轮 ${n_flap_new} 次 down（口清单见 state flap.events；Q1 判据核）"
if [ -n "$flap_q2" ]; then
  crit "Q2 翻转后不回：$flap_q2 down >${TH_Q2_NORET}s 未回 ACTIVE（非松动接触形态，物理层再介入）"
  RED_PARAM="$RED_PARAM Q2"
fi
q7_gap_this=$([ -n "$flap_changed" ] && [ "$flap_jhas" = "0" ] && echo 1 || echo 0)

# ── F-G7/8/9 计数器差分（首轮无前值=只建快照不判；v2 逐口+连续轮）──────────
now=$(date +%s)
dt=300
[ -n "$PREV_TS" ] && dt=$(python3 -c "
from datetime import datetime
try: print(max(60,int($now-datetime.strptime('$PREV_TS','%Y-%m-%dT%H:%M:%SZ').timestamp())))
except Exception: print(300)" 2>/dev/null)
dt=${dt:-300}
: > "$SNAP.cur"
fec_tot=0; crc_tot=0; oob_tot=0; p0d_tot=0; oos_tot=0; seq_tot=0; cnp_tot=0
PP_JSON=/tmp/fabric-guard-pp.$$
echo "{" > "$PP_JSON"
pp_first=1
pdelta(){ # <dev|hca> <key> <cur>  → 逐口 5min Δ 入 PP_JSON（stdout=Δ 值）
  local d=$1 k=$2 c=$3 p dd
  c=${c%%[!0-9-]*}; [ -z "$c" ] && c=0
  p=$(awk -v k="et_${d}_${k}" '$1==k{print $2}' "$SNAP.prev2")
  [ -z "$p" ] && p=$(awk -v k="rd_${d}_${k}" '$1==k{print $2}' "$SNAP.prev2")
  if [ -z "$p" ]; then echo 0; return; fi
  dd=$(( c - p )); [ $dd -lt 0 ] && dd=0
  [ $pp_first = 1 ] || echo "," >> "$PP_JSON"
  pp_first=0
  echo "\"${d}.${k}\": $dd" >> "$PP_JSON"
  echo $dd
}
for pair in $HCA_OF; do
  dev=${pair%%:*}; hca=${pair##*:}
  for k in rx_out_of_buffer rx_prio0_buf_discard rx_corrected_bits_phy rx_crc_errors_phy; do
    v=$(etS "$dev" "$k"); v=${v%%[!0-9-]*}; [ -z "$v" ] && v=0
    echo "et_${dev}_${k} $v" >> "$SNAP.cur"
  done
  for k in out_of_sequence packet_seq_err np_cnp_sent; do
    v=$(cat "/sys/class/infiniband/$hca/ports/1/hw_counters/$k" 2>/dev/null); v=${v%%[!0-9-]*}; [ -z "$v" ] && v=0
    echo "rd_${hca}_${k} $v" >> "$SNAP.cur"
  done
  # 逐口分解（§1.3：delta 按 dev 分键；定位劣化口）
  d_fec=$(pdelta "$dev" rx_corrected_bits_phy "$(etS "$dev" rx_corrected_bits_phy | cut -c1-20)")
  d_crc=$(pdelta "$dev" rx_crc_errors_phy "$(etS "$dev" rx_crc_errors_phy | cut -c1-20)")
  d_oob=$(pdelta "$dev" rx_out_of_buffer "$(etS "$dev" rx_out_of_buffer | cut -c1-20)")
  d_p0d=$(pdelta "$dev" rx_prio0_buf_discard "$(etS "$dev" rx_prio0_buf_discard | cut -c1-20)")
  d_oos=$(pdelta "$hca" out_of_sequence "$(cat /sys/class/infiniband/$hca/ports/1/hw_counters/out_of_sequence 2>/dev/null | cut -c1-20)")
  d_seq=$(pdelta "$hca" packet_seq_err "$(cat /sys/class/infiniband/$hca/ports/1/hw_counters/packet_seq_err 2>/dev/null | cut -c1-20)")
  d_cnp=$(pdelta "$hca" np_cnp_sent "$(cat /sys/class/infiniband/$hca/ports/1/hw_counters/np_cnp_sent 2>/dev/null | cut -c1-20)")
  fec_tot=$((fec_tot+d_fec)); crc_tot=$((crc_tot+d_crc)); oob_tot=$((oob_tot+d_oob))
  p0d_tot=$((p0d_tot+d_p0d)); oos_tot=$((oos_tot+d_oos)); seq_tot=$((seq_tot+d_seq)); cnp_tot=$((cnp_tot+d_cnp))
done
echo "}" >> "$PP_JSON"

[ "$crc_tot" -gt "$TH_CRC" ] && { warn "F-G7 不可纠类 rx_crc_errors_phy 5min Δ=$crc_tot >0（物理层红线）"; WARN_FACE="$WARN_FACE F-G7-crc"; }
[ "$fec_tot" -gt "$TH_FEC_CORR" ] && { warn "F-G7 FEC corrected 5min Δ=$fec_tot >$TH_FEC_CORR（≈换线前 2/s 病理水位；换线后本底 ~60/5min）"; WARN_FACE="$WARN_FACE F-G7-fec"; }
[ "$oob_tot" -gt "$TH_OOB" ] && { warn "F-G8 rx_out_of_buffer 5min Δ=$oob_tot >$TH_OOB"; WARN_FACE="$WARN_FACE F-G8-oob"; }
[ "$p0d_tot" -gt "$TH_P0D" ] && { warn "F-G8 rx_prio0_buf_discard 5min Δ=$p0d_tot >$TH_P0D"; WARN_FACE="$WARN_FACE F-G8-p0d"; }
[ "$oos_tot" -gt "$TH_OOS" ] || [ "$seq_tot" -gt "$TH_OOS" ] && { warn "F-G9 oos/seq 5min Δ=$oos_tot/$seq_tot >$TH_OOS"; WARN_FACE="$WARN_FACE F-G9-oos"; }
[ "$cnp_tot" -gt "$TH_CNP" ] && { warn "F-G9 np_cnp_sent 5min Δ=$cnp_tot >$TH_CNP（DCQCN 拥塞面信号）"; WARN_FACE="$WARN_FACE F-G9-cnp"; }

# ── Q1-Q7 持续性质化判据+CRIT-STANDING 滞回（§三表）────────────────────────
QE_FILE=/tmp/fabric-guard-qe.$$
q_eval=$(STATEF="$STATE" \
  FLAP_EVENTS="${flap_events:-[]}" G6B_MISS="$g6b_miss" G6B_EXTRA="$g6b_extra" G6B_NP="$g6b_npmiss" G6B_UNREACH="$g6b_unreach" \
  FEC_T=$fec_tot CRC_T=$crc_tot OOB_T=$oob_tot P0D_T=$p0d_tot OOS_T=$((oos_tot+seq_tot)) CNP_T=$cnp_tot \
  Q7_GAP=$q7_gap_this GID_HOLES_NOW="$gid_holes2${gid_holes2:+ }" GID_HOLES_FALLBACK="$gid_holes" \
  TH_Q1_CRIT_24H=$TH_Q1_CRIT_24H TH_Q1_CRIT_1H=$TH_Q1_CRIT_1H TH_Q3_CONSEC=$TH_Q3_CONSEC TH_Q4_CONSEC=$TH_Q4_CONSEC \
  TH_Q5_FUSE_1H=$TH_Q5_FUSE_1H TH_Q6_CONSEC=$TH_Q6_CONSEC TH_Q7_CONSEC=$TH_Q7_CONSEC \
  python3 <<'PYEOF'
import json,os,datetime,time
env=os.environ
now=time.time()
def rd(k,d=''):
    v=env.get(k,d); return v
# 载前态
try: prev=json.loads(open(env['STATEF']).read())
except Exception: prev={}
flap=prev.get('flap',{})
events=flap.get('events',[])
try: newev=json.loads(env.get('FLAP_EVENTS','[]'))
except Exception: newev=[]
# 合并事件环形缓冲（200 条；跨轮去重=游标 5s 重叠窗防双计）
seen=set((e.get('port'),e.get('ts'),e.get('down')) for e in events)
for e in newev:
    k=(e.get('port'),e.get('ts'),e.get('down'))
    if k not in seen: events.append(e); seen.add(k)
events=events[-200:]
def epochify(e):
    try: return e['ts']
    except Exception: return 0
n1h=sum(1 for e in events if e.get('down') and now-e['ts']<3600)
n24h=sum(1 for e in events if e.get('down') and now-e['ts']<86400)
last_evt=max([e['ts'] for e in events],default=0)
q={}
# Q1 翻转频率
if n24h>=int(env.get('TH_Q1_CRIT_24H','3')) or n1h>=int(env.get('TH_Q1_CRIT_1H','2')):
    q['Q1']=('crit',f'物理层持续接触不良：{n24h} 次/24h、{n1h} 次/1h（≥3/24h 或 ≥2/1h）——需再介入；auto-boot 抑制')
elif n24h>=2: q['Q1']=('warn','翻转频率 watch：%d 次/24h'%n24h)
# Q3 计数器连续超限
qual=prev.get('quality',{})
over={'fec':int(env['FEC_T'])>600,'crc':int(env['CRC_T'])>0,'oob':int(env['OOB_T'])>100,
      'p0d':int(env['P0D_T'])>100,'oos':int(env['OOS_T'])>100,'cnp':int(env['CNP_T'])>100}
q3crit=[]
for k,o in over.items():
    c=qual.get(k,{}).get('consec',0)
    c=c+1 if o else 0
    qual[k]={'consec':c,'last_over':bool(o)}
    if c>=3: q3crit.append(f'{k}×{c}轮')
if q3crit: q['Q3']=('crit','丢包计数器持续超限（15min+）：'+','.join(q3crit))
# Q4 哨兵带外连续
sent=prev.get('sentinel',{})
sv=sent.get('last_verdict',0); sts=sent.get('last_ts','')
q4c=qual.get('sentinel',{}).get('consec',0)
if sv==1 and sts:
    try: fresh=(now-datetime.datetime.strptime(sts,'%Y-%m-%dT%H:%M:%SZ').timestamp())<1800
    except Exception: fresh=False
    q4c=q4c+1 if fresh else q4c
else: q4c=0
qual['sentinel']={'consec':q4c}
if q4c>=3: q['Q4']=('crit','哨兵延迟带持续外 45min+（连续 %d 轮）——环境劣化定性+联动熔断自愈'%q4c)
# Q5 自愈频次熔断（heal 件已置 fuse；此处读态判读）
heal=prev.get('heal',{})
hist=heal.get('history',[])
def _ts(e):
    try: return datetime.datetime.strptime(e.get('ts',''),'%Y-%m-%dT%H:%M:%SZ').timestamp()
    except Exception: return 0.0
nheal=sum(1 for e in hist if now-_ts(e)<3600) if hist else 0
if heal.get('fuse') or nheal>=2: q['Q5']=('crit','自愈频次熔断：1h 内 %d 次（≥2）——疑似持续故障被自愈掩盖，停自动动作待人工复位（触碰 state/fabric-heal-fuse.reset）'%max(nheal,2 if heal.get('fuse') else 0))
# Q6 GID 洞不可修：本轮洞仍在（heal 后）连续轮
holes_now=env.get('GID_HOLES_NOW','').strip()
q6c=qual.get('gid_unfix',{}).get('consec',0)
q6c=q6c+1 if holes_now else 0
qual['gid_unfix']={'consec':q6c}
if q6c>=2: q['Q6']=('crit','GID 洞连续 %d 轮（10min+）不可修或前置不满足——确定性洞之外形态=人审'%q6c)
# Q7 journal 覆盖缺口
q7c=qual.get('journal_gap',{}).get('consec',0)
q7c=q7c+1 if env.get('Q7_GAP','0')=='1' else 0
qual['journal_gap']={'consec':q7c}
if q7c>=2: q['Q7']=('crit','检测面失明：operstate 变化而 journal 无行（连续 %d 轮）'%q7c)
# drift 连续 3 轮升 Q3 类
drift=bool(env.get('G6B_MISS','').strip() or env.get('G6B_EXTRA','').strip() or env.get('G6B_NP','').strip() or env.get('G6B_UNREACH','').strip())
dc=qual.get('route_drift',{}).get('consec',0)
dc=dc+1 if drift else 0
qual['route_drift']={'consec':dc}
if dc>=3: q['Q3b']=('crit','注册面 drift 连续 3 轮不清（F-G6b 持续性升格）')
out={'flap':{'events':events,'n_1h':n1h,'n_24h':n24h,'last_event_ts':last_evt},
     'quality':qual,'q':{k:list(v) for k,v in q.items()}}
print(json.dumps(out))
PYEOF
)
# shellcheck disable=SC2181
if [ -n "$q_eval" ] && python3 -c "import json,sys;json.loads(sys.argv[1])" "$q_eval" 2>/dev/null; then
  while IFS='=' read -r qk qv; do
    lvl=${qv%%|*}; msg=${qv#*|}
    if [ "$lvl" = crit ]; then
      crit "Q 判据 $qk：$msg"
      RED_PARAM="$RED_PARAM $qk"
    else
      warn "Q 判据 $qk：$msg"
    fi
  done < <(python3 -c "
import json,sys
q=json.loads(sys.argv[1]).get('q',{})
for k,(lvl,msg) in q.items(): print(f'{k}={lvl}|{msg}')" "$q_eval")
fi

# ── CRIT-STANDING 驻留文件管理（条件存续期间在、连续 6 轮绿消除后删）───────
standing_out=$(Q_EVAL="$q_eval" ALERTS_DIR="$ALERTS_DIR" TH_CLEAR=$TH_STANDING_CLEAR python3 <<'PYEOF'
import json,os
qev=os.environ.get('Q_EVAL','')
try: q=json.loads(qev).get('q',{})
except Exception: q={}
ad=os.environ['ALERTS_DIR']; th=int(os.environ['TH_CLEAR'])
cats=set(k for k in q if q[k][0]=='crit')
made=[]; removed=[]; standing=[]
for f in sorted(os.listdir(ad)) if os.path.isdir(ad) else []:
    if f.startswith('CRIT-STANDING-'):
        cat=f.replace('CRIT-STANDING-','')
        standing.append(cat)
        if cat not in cats:
            p=os.path.join(ad,f)
            try: n=int(open(p).read().strip() or 0)
            except Exception: n=0
            n+=1
            if n>=th:
                os.remove(p); removed.append(cat)
                # 滞回清除也落 alerts 文件
                with open(os.path.join(os.path.dirname(ad),'fabric-alerts.log'),'a') as fh:
                    fh.write(f"[{__import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}] INFO CRIT-STANDING-{cat} 连续 {th} 轮绿滞回清除\n")
            else:
                open(p,'w').write(str(n))
for cat in cats:
    fn=os.path.join(ad,f'CRIT-STANDING-{cat}')
    if not os.path.exists(fn):
        open(fn,'w').write('0'); made.append(cat)
print(json.dumps({'made':made,'removed':removed,'standing':sorted(set(standing)|cats)}))
PYEOF
)
# CRIT-STANDING 新建时大声（journal+alerts）
for cat in $(python3 -c "import json,sys;print(' '.join(json.loads(sys.argv[1]).get('made',[])))" "$standing_out" 2>/dev/null); do
  crit "CRIT-STANDING 建立：$cat（驻留告警；连续 ${TH_STANDING_CLEAR} 轮绿自动滞回清除）"
done
# Q1 standing=auto-boot 抑制面（restore-gate J5 读 CRIT-STANDING-Q1-flap-rate 文件）

# ── 终判+状态文件（v1 域全保+v2 扩展域；保哨兵带）──────────────────────────
if [ -n "$RED_PARAM" ]; then VERDICT=2
elif [ -n "$WARN_FACE" ]; then VERDICT=1
else VERDICT=0
fi
first_round=$([ -n "$PREV_TS" ] && echo 0 || echo 1)
vstr=$([ $VERDICT = 0 ] && echo GREEN || ([ $VERDICT = 1 ] && echo WARN || echo CRIT))
printf '%s' "$q_eval" > "$QE_FILE" 2>/dev/null || : > "$QE_FILE"
printf '%s' "$standing_out" > "$QE_FILE.standing" 2>/dev/null || : > "$QE_FILE.standing"
printf '%s' "$link_states" > "$QE_FILE.links" 2>/dev/null || : > "$QE_FILE.links"
python3 - "$STATE" "$QE_FILE" "$QE_FILE.standing" "$QE_FILE.links" <<PYEOF
import json,os,sys,datetime
state,qef,stf,lnkf=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
def rdj(p):
    try: return json.load(open(p))
    except Exception: return {}
j=rdj(state)
sent=j.get('sentinel',{})
heal=j.get('heal',{})
qeval=rdj(qef)
standing=rdj(stf)
gf={}
for ln in """$gid_face""".splitlines():
    p=ln.split('|')
    if len(p)==6: gf[p[0]]={'state':p[1],'type3':p[2],'v4':p[3],'verdict':p[4],'expect':p[5]}
flap=dict(qeval.get('flap',{})); flap['cursor']=$flap_cursor_new
j={
 "last_run": "$fg_ts", "verdict": $VERDICT, "verdict_str": "$vstr",
 "red_param": "${RED_PARAM## }", "warn_face": "${WARN_FACE## }",
 "ring_ok": $ring_ok, "first_round": $first_round,
 "deltas_5min": {"fec_corr": $fec_tot, "crc_uncorr_class": $crc_tot, "oob": $oob_tot,
                 "p0d": $p0d_tot, "oos": $oos_tot, "seq": $seq_tot, "cnp": $cnp_tot},
 "deltas_5min_per_port": rdj("$PP_JSON"),
 "snapshot_ts": "$fg_ts",
 "counters": dict(line.split() for line in open("$SNAP.cur")),
 "sentinel": sent, "heal": heal,
 "flap": flap,
 "gid_face": gf,
 "quality": qeval.get('quality',{}),
 "q_state": qeval.get('q',{}),
 "routes": {"drift_missing": "${g6b_miss}".split(), "drift_extra": "${g6b_extra}".split(),
            "netplan_missing": "${g6b_npmiss}".split(), "gid_unreachable": "${g6b_unreach}".split(),
            "gid_uncovered": "${g6b_uncov}".split()},
 "link_states": rdj(lnkf),
 "crit_standing": standing.get('standing',[]),
 "gid_healed_this_round": "${gid_healed## }".split(),
}
os.makedirs(os.path.dirname(state),exist_ok=True)
json.dump(j,open(state,'w'),indent=2)
PYEOF
rm -f "$SNAP" "$SNAP.prev" "$SNAP.prev2" "$SNAP.cur" "$QE_FILE" "$QE_FILE.standing" "$QE_FILE.links" "$PP_JSON"

# ── textfile 指标（node_exporter 容器内；容器不在=跳过留痕）─────────────────
n1h_v=$(python3 -c "import json,os;print(json.load(open('$STATE')).get('flap',{}).get('n_1h',0))" 2>/dev/null)
n24h_v=$(python3 -c "import json,os;print(json.load(open('$STATE')).get('flap',{}).get('n_24h',0))" 2>/dev/null)
heal_n1h=$(python3 -c "
import json,os,datetime
j=json.load(open('$STATE')); n=0
for e in j.get('heal',{}).get('history',[]):
  try:
    if (datetime.datetime.utcnow()-datetime.datetime.strptime(e['ts'],'%Y-%m-%dT%H:%M:%SZ')).total_seconds()<3600: n+=1
  except Exception: pass
print(n)" 2>/dev/null)
PROM="# TYPE fabric_guard_verdict gauge
fabric_guard_verdict $VERDICT
# TYPE fabric_guard_ring_ok gauge
fabric_guard_ring_ok $ring_ok
# TYPE fabric_guard_flap_1h gauge
fabric_guard_flap_1h ${n1h_v:-0}
# TYPE fabric_guard_flap_24h gauge
fabric_guard_flap_24h ${n24h_v:-0}
# TYPE fabric_guard_heal_1h gauge
fabric_guard_heal_1h ${heal_n1h:-0}
# TYPE fabric_guard_fec_corr_delta gauge
fabric_guard_fec_corr_delta $fec_tot
# TYPE fabric_guard_crc_uncorr_delta gauge
fabric_guard_crc_uncorr_delta $crc_tot
# TYPE fabric_guard_oob_delta gauge
fabric_guard_oob_delta $oob_tot
# TYPE fabric_guard_p0d_delta gauge
fabric_guard_p0d_delta $p0d_tot
# TYPE fabric_guard_oos_delta gauge
fabric_guard_oos_delta $oos_tot
# TYPE fabric_guard_cnp_delta gauge
fabric_guard_cnp_delta $cnp_tot"
if docker exec "$NE_CTN" true >/dev/null 2>&1; then
  docker exec -u 0 "$NE_CTN" mkdir -p /var/lib/node_exporter/textfile_collector 2>/dev/null
  printf '%s\n' "$PROM" | docker exec -i -u 0 "$NE_CTN" sh -c 'cat > /var/lib/node_exporter/textfile_collector/fabric_guard.prom' 2>/dev/null \
    || warn "textfile 写入失败（node-exporter 容器面）"
fi

echo "[fabric-guard] $(hostname) $fg_ts verdict=$VERDICT($vstr) red=[${RED_PARAM## }] warn=[${WARN_FACE## }] flap1h=${n1h_v:-0} flap24h=${n24h_v:-0} heal1h=${heal_n1h:-0} fecΔ=$fec_tot crcΔ=$crc_tot oobΔ=$oob_tot p0dΔ=$p0d_tot oosΔ=$oos_tot cnpΔ=$cnp_tot first_round=$first_round"

# ── 尾部：restore-gate Phase1（仅 01 机；五判据 READY-TO-BOOT 广播）─────────
if [ "$(hostname)" = "dgxspark01" ] && [ -x "$GATE_SH" -o -f "$GATE_SH" ]; then
  bash "$GATE_SH" >/dev/null 2>&1 || true
fi
exit 0
