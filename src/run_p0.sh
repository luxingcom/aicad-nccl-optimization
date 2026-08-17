#!/bin/bash
# run_p0.sh — 4 机并行跑 p0_inversion.py, 汇总 rank0 输出
set -uo pipefail
MASTER_ADDR=<LAN-IP>
MASTER_PORT=27111
declare -A RANK_HOST=( [0]="<node1>" [1]="<node2>" [2]="<node4>" [3]="<node3>" )
SCRIPT="p0_inversion.py"
OUTDIR="/opt/2hop-s1/out-s2"
mkdir -p "$OUTDIR"
RUNID=$(date +%Y%m%d_%H%M%S)
RUN_TIMEOUT="${RUN_TIMEOUT:-600}"
echo "=== run_p0 runid=$RUNID ==="
declare -A PIDS
for r in 0 1 2 3; do
  h="${RANK_HOST[$r]}"
  if [ "$h" = "<node1>" ]; then
    ( echo AS12<REDACTED> | sudo -S timeout "$RUN_TIMEOUT" docker exec -e RANK=$r -e WORLD_SIZE=4 \
        -e MASTER_ADDR=$MASTER_ADDR -e MASTER_PORT=$MASTER_PORT \
        2hop-s1-rank${r} python3 /opt/2hop-s1/$SCRIPT > "$OUTDIR/p0-rank${r}-${RUNID}.log" 2>&1 ) &
  else
    ( ssh -o BatchMode=yes "$h" "echo AS12<REDACTED> | sudo -S timeout '$RUN_TIMEOUT' docker exec -e RANK=$r -e WORLD_SIZE=4 \
        -e MASTER_ADDR=$MASTER_ADDR -e MASTER_PORT=$MASTER_PORT \
        2hop-s1-rank${r} python3 /opt/2hop-s1/$SCRIPT" > "$OUTDIR/p0-rank${r}-${RUNID}.log" 2>&1 ) &
  fi
  PIDS[$r]=$!
done
declare -A RC
for r in 0 1 2 3; do wait "${PIDS[$r]}"; RC[$r]=$?; done
for r in 0 1 2 3; do
  h="${RANK_HOST[$r]}"
  ssh -o BatchMode=yes "$h" "echo AS12<REDACTED> | sudo -S docker exec 2hop-s1-rank${r} pkill -9 -f '$SCRIPT' 2>/dev/null" >/dev/null 2>&1 || true
done
echo "=== rc: 0=${RC[0]} 1=${RC[1]} 2=${RC[2]} 3=${RC[3]} ==="
cat "$OUTDIR/p0-rank0-${RUNID}.log"
echo "RUNID=$RUNID"
