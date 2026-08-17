#!/bin/bash
# run_2hop_bench.sh — 4 机并行跑 twohop_bench.py / cudagraph_test.py, 汇总 rank0 输出
# 用法(在 rank0=<node1> 上):
#   bash run_2hop_bench.sh bench [NCCL_PROTO=LL|Simple|...] [NCCL_DEBUG=WARN]
#   bash run_2hop_bench.sh cudagraph [NCCL_PROTO=Simple] [NCCL_DEBUG=WARN]
set -uo pipefail
MODE=${1:?usage: run_2hop_bench.sh <bench|cudagraph> [env...]}
MASTER_ADDR=<LAN-IP>
MASTER_PORT=27000
declare -A RANK_HOST=( [0]="<node1>" [1]="<node2>" [2]="<node4>" [3]="<node3>" )
EXTRA=()
shift
for e in "$@"; do EXTRA+=(-e "$e"); done
OUTDIR=/opt/2hop-s1/out
(echo AS12<REDACTED> | sudo -S mkdir -p "$OUTDIR" 2>/dev/null) || mkdir -p "$OUTDIR"
RUNID=$(date +%Y%m%d_%H%M%S)
SCRIPT="twohop_bench.py"
[ "$MODE" = "cudagraph" ] && SCRIPT="cudagraph_test.py"
echo "=== run_2hop $MODE extra=($*) runid=$RUNID ==="

sudorun() { echo AS12<REDACTED> | sudo -S "$@"; }
declare -A PIDS
for r in 0 1 2 3; do
  h="${RANK_HOST[$r]}"
  if [ "$h" = "<node1>" ]; then
    ( sudorun docker exec "${EXTRA[@]}" -e RANK=$r -e WORLD_SIZE=4 \
        -e MASTER_ADDR=$MASTER_ADDR -e MASTER_PORT=$MASTER_PORT \
        "2hop-s1-rank${r}" python3 /opt/2hop-s1/$SCRIPT \
        > "$OUTDIR/${MODE}-rank${r}-${RUNID}.log" 2>&1 ) &
  else
    ( ssh -o BatchMode=yes "$h" "echo AS12<REDACTED> | sudo -S docker exec ${EXTRA[*]} -e RANK=$r -e WORLD_SIZE=4 \
        -e MASTER_ADDR=$MASTER_ADDR -e MASTER_PORT=$MASTER_PORT \
        2hop-s1-rank${r} python3 /opt/2hop-s1/$SCRIPT" \
        > "$OUTDIR/${MODE}-rank${r}-${RUNID}.log" 2>&1 ) &
  fi
  PIDS[$r]=$!
done
for r in 0 1 2 3; do wait "${PIDS[$r]}"; done
echo "=== rank0 output ($OUTDIR/${MODE}-rank0-${RUNID}.log) ==="
cat "$OUTDIR/${MODE}-rank0-${RUNID}.log"
echo "=== RUNID=$RUNID ==="
