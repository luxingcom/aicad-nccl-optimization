#!/bin/bash
# fabric-sentinel.sh — NCCL 32MB AR 性能哨兵（idle 双确认门禁；L4 只告警）
# 谱系：KNAPCIO-FABRIC-TUNING-20261007.md §3.6；事故卡 §九 纪律注入：
#   idle 双确认门 = health 200 AND /v1/loads running=0/waiting=0（/health 不反映 running-req
#   的盲区以事故#1 为案例——严守，任何一轮发射前双确认）
# 探测形：torch 32MB fp32 all_reduce ×20（引擎同款容器/同款 NCCL env/同款双库；
#   rendezvous=env:// MASTER_ADDR 直连——MPI 免疫，2026-10-07 段4 MPI OOB modex 阻断的
#   工程绕行；口径=torch AR 非nccl-tests，带=自基线中值±25%，历史健康锚 2496.49µs(nccl-tests
#   口径)仅参考不作列锚）
# 基线带：fabric-guard.json sentinel.band_us（--baseline 模式 5 发建带）
# 用法：fabric-sentinel.sh [--baseline]
set -u
STATE=/opt/dsv41-mesh/state/fabric-guard.json
ALERTS=/opt/dsv41-mesh/fabric-alerts.log
NE_CTN="${NODE_EXPORTER_CTN:-aicad-node-exporter}"
API="${SENTINEL_API:-http://127.0.0.1:8899}"
MODE="${1:-check}"
PROBE_PY=~/migrate-assets/dsv41/sentinel/ar_probe.py
IMAGE="192.168.5.187:5000/lmsysorg/sglang:main-79cafec0"
PIP_NCCL=/opt/sglang/lib/python3.12/site-packages/nvidia/nccl/lib/libnccl.so.2
MPORT="${SENTINEL_MPORT:-29617}"
# root 跑法（systemd/sudo）下 ssh 免密钥在用户侧——root 时降身用户跑 ssh；docker root 直用
if [ "$(id -u)" = 0 ]; then SSH="sudo -u liux***ya ssh -o BatchMode=yes -o ConnectTimeout=8"
else SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"; fi

ts(){ date -u +%FT%TZ; }
alert(){ echo "[SENTINEL $(ts)] $*" | tee -a "$ALERTS"; logger -t fabric-sentinel -p daemon.err "$*"; }

# ── idle 双确认门（硬门：不过=SKIP，绝不与在飞请求共存跑 GPU 测试）────────
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/health" 2>/dev/null)
loads=$(curl -s --max-time 5 "$API/v1/loads" 2>/dev/null)
running=$(python3 -c "
import json
try:
  j=json.loads('''$loads''')
  ws=j if isinstance(j,list) else [j]
  print(sum(int(w.get('num_running_reqs',w.get('running_reqs',0)) or 0) for w in ws))
except Exception: print(-1)")
waiting=$(python3 -c "
import json
try:
  j=json.loads('''$loads''')
  ws=j if isinstance(j,list) else [j]
  print(sum(int(w.get('num_queue_reqs',w.get('waiting_reqs',0)) or 0) for w in ws))
except Exception: print(-1)")
if [ "$health" != 200 ] || [ "$running" != 0 ] || [ "$waiting" != 0 ]; then
  echo "[sentinel] SKIP：idle 双确认门未过（health=$health running=$running waiting=$waiting）"
  exit 0
fi

# ── 单轮探测：四机同起容器（head 本机 rank0，worker ssh rank1-3）───────────
NCTN=fabric-sentinel-probe
NCCL_ENV="-e NCCL_NET=IB \
 -e NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 \
 -e NCCL_IB_GID_INDEX=3 -e NCCL_SOCKET_IFNAME=enP7s7 -e GLOO_SOCKET_IFNAME=enP7s7 \
 -e NCCL_DEBUG=WARN -e NCCL_ALGO=RING -e NCCL_BUFFSIZE=8388608 -e NCCL_CROSS_NIC=1 \
 -e NCCL_CUMEM_ENABLE=0 -e NCCL_CUMEM_HOST_ENABLE=0 -e NCCL_IB_DISABLE=0 \
 -e NCCL_IB_MERGE_NICS=0 -e NCCL_IB_RETRY_CNT=7 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
 -e NCCL_IB_TIMEOUT=1000 -e NCCL_IB_TOS=46 -e NCCL_IGNORE_CPU_AFFINITY=1 \
 -e NCCL_LL128_BUFFSIZE=-2 -e NCCL_MAX_NCHANNELS=4 -e NCCL_MIN_NCHANNELS=4 \
 -e NCCL_NET_PLUGIN=none -e NCCL_P2P_DISABLE=1 -e NCCL_PROTO=LL,LL128,Simple \
 -e NCCL_SHM_DISABLE=1 -e NCCL_TUNER_THRESHOLD=40960 -e NCCL_VERSION=2.28.3-1 \
 -e \"LD_PRELOAD=/opt/ncclpin.so:$PIP_NCCL\""
RUN_HC() {  # RUN_HC <rank> <host|-> <extra-timeout-s>
  local r=$1 h=$2 ito=$3
  local uhome=/home/liux***ya   # 固定用户路径（root 跑法下 $HOME=/root 会失锚——docker -v 静默建空目录）
  local cmd="docker run --rm --name $NCTN-r$r --network host --ipc host --gpus all \
    --device /dev/infiniband --memory 8g --ulimit memlock=-1 --ulimit stack=67108864 \
    -v $uhome/migrate-assets/nccl-ringonly:/opt/nccl-ringonly:ro \
    -v $uhome/migrate-assets/ncclpin.so:/opt/ncclpin.so:ro \
    -v $uhome/migrate-assets/nccl-ringonly/libnccl.so.2.30.7:$PIP_NCCL:ro \
    -v $uhome/migrate-assets/dsv41/sentinel:/sentinel:ro \
    $NCCL_ENV \
    -e MASTER_ADDR=192.168.5.186 -e MASTER_PORT=$MPORT -e WORLD_SIZE=4 -e RANK=$r \
    $IMAGE python3 /sentinel/ar_probe.py"
  if [ "$h" = "-" ]; then timeout $ito $cmd; else timeout $ito $SSH "$h" "$cmd"; fi
}

probe(){  # 发射一轮 → stdout=median_us（空=失败）
  local log=/tmp/fabric-sentinel-probe.$$
  RUN_HC 1 dgxspark02 240 >"$log.w1" 2>&1 &
  RUN_HC 2 dgxspark04 240 >"$log.w2" 2>&1 &
  RUN_HC 3 dgxspark03 240 >"$log.w3" 2>&1 &
  RUN_HC 0 - 240 >"$log.h" 2>&1
  wait
  grep -h -m1 "^AR32M_US_MEDIAN" "$log.h" 2>/dev/null | awk '{print $2}'
  grep -hE "NCCL WARN|Error|error" "$log".h "$log".w1 "$log".w2 "$log".w3 2>/dev/null | head -4 | sed 's/^/[sentinel-log] /'
  rm -f "$log".h "$log".w1 "$log".w2 "$log".w3
}

if [ "$MODE" = "--baseline" ]; then
  echo "[sentinel] 基线采集中（5 发 32MB torch AR，引擎 idle 双确认已过 health=$health running=$running waiting=$waiting）"
  vals=()
  for i in 1 2 3 4 5; do
    v=$(probe); [ -z "$v" ] && v=$(probe)
    [ -z "$v" ] && { echo "[sentinel] 发$i 无读数（跳过）"; continue; }
    vals+=("$v"); echo "[sentinel] 发$i ${v}us"
  done
  [ "${#vals[@]}" -ge 3 ] || { echo "[sentinel] 有效发数<3，基线不成（不写带）"; exit 1; }
  med=$(printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{if(NR%2)print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}')
  lo=$(python3 -c "print(int($med*0.75))"); hi=$(python3 -c "print(int($med*1.25))")
  SENT_SHOTS="${vals[*]}" python3 - "$STATE" "$med" "$lo" "$hi" <<'PYEOF'
import json,sys,os,datetime
state,med,lo,hi=sys.argv[1],float(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
j=json.load(open(state)) if os.path.exists(state) else {}
j['sentinel']={"band_us":{"median":med,"lo":lo,"hi":hi,"pct":25},
               "baseline_ts":datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
               "shots":os.environ.get('SENT_SHOTS',''),"caliber":"torch-AR-32MB-fp32-envrendezvous"}
os.makedirs(os.path.dirname(state),exist_ok=True)
json.dump(j,open(state,'w'),indent=2)
PYEOF
  echo "[sentinel] 带已写：median=${med}us band=${lo}-${hi}us（±25%，口径=torch AR）"
  exit 0
fi

# ── 带外检测模式 ──
read -r lo hi < <(python3 -c "import json;j=json.load(open('$STATE'));b=j.get('sentinel',{}).get('band_us',{});print(b.get('lo',''),b.get('hi',''))" 2>/dev/null)
if [ -z "$lo" ] || [ -z "$hi" ] || [ "$lo" = "None" ]; then
  echo "[sentinel] 无带（先 --baseline 建带）"; exit 0
fi
v=$(probe)
if [ -z "$v" ]; then echo "[sentinel] 本轮无读数（工具面失败，留痕不告警——避免工具故障误报性能带外）"; exit 0; fi
verdict=0
if [ "$v" -gt "$hi" ]; then verdict=1; alert "CRIT 哨兵带外：32MB AR ${v}us > 带${lo}-${hi}us（中值×1.25）——环境劣化形（OPEN-28 家族）分钟级告警"; fi
[ "$v" -lt "$lo" ] && { echo "[sentinel] 带下越（${v}us < ${lo}us，更快=环境变好或量具面异动，留痕不告警）"; verdict=0; }
python3 - "$STATE" "$v" "$verdict" <<'PYEOF'
import json,sys,os,datetime
state,v,verdict=sys.argv[1],sys.argv[2],sys.argv[3]
j=json.load(open(state)) if os.path.exists(state) else {}
s=j.get('sentinel',{}); s['last_us']=float(v); s['last_verdict']=int(verdict); s['last_ts']=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
j['sentinel']=s; json.dump(j,open(state,'w'),indent=2)
PYEOF
PROM="# TYPE fabric_sentinel_ar32m_us gauge
fabric_sentinel_ar32m_us $v
# TYPE fabric_sentinel_verdict gauge
fabric_sentinel_verdict $verdict"
if docker exec "$NE_CTN" true >/dev/null 2>&1; then
  docker exec -u 0 "$NE_CTN" mkdir -p /var/lib/node_exporter/textfile_collector 2>/dev/null
  printf '%s\n' "$PROM" | docker exec -i -u 0 "$NE_CTN" sh -c 'cat > /var/lib/node_exporter/textfile_collector/fabric_sentinel.prom' 2>/dev/null || true
fi
echo "[sentinel] 32MB AR ${v}us（带 ${lo}-${hi}us）verdict=$verdict"
exit 0
