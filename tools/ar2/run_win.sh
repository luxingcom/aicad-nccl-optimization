#!/bin/bash
# run_win.sh <name> <probe args...> — v5-rank* 容器并行跑一轮 probe（窗口 4 复用件）
# 纪律: 跑前/跑后 pkill 清僵尸; timeout 包裹; env 透传 AR2_ENV="A=1 B=2"
set -u
NAME=${1:?run-name}; shift
declare -A RANK_HOST=( [0]="dgxspark01" [1]="dgxspark02" [2]="dgxspark04" [3]="dgxspark03" )
PEERS="192.168.5.186,192.168.5.187,192.168.5.189,192.168.5.188"
OUT=~/sparkring-kit/ringonlyV5/results; mkdir -p "$OUT"; RUNID=$(date +%H%M%S)
AR2_ENV=${AR2_ENV:-}
TMO=${TMO:-420}

for r in 0 1 2 3; do
  h="${RANK_HOST[$r]}"
  PRE="pkill -9 ar2_probe 2>/dev/null; sleep 0.2;"
  RUN="[ -n "$AR2_ENV" ] && export $AR2_ENV; /src/build-local/ar2_probe --rank $r --peers $PEERS --port 9500 $*"
  if [ "$h" = dgxspark01 ]; then
    ( timeout $TMO docker exec v5-rank$r bash -c "$PRE $RUN" > "$OUT/$NAME-rank$r-$RUNID.log" 2>&1; \
      docker exec v5-rank$r pkill -9 ar2_probe 2>/dev/null ) &
  else
    ( timeout $TMO ssh -o BatchMode=yes "$h" "docker exec v5-rank$r bash -c '$PRE $RUN'" > "$OUT/$NAME-rank$r-$RUNID.log" 2>&1; \
      timeout 20 ssh -o BatchMode=yes "$h" "docker exec v5-rank$r pkill -9 ar2_probe 2>/dev/null" 2>/dev/null ) &
  fi
done
wait
echo "=== $NAME (RUNID=$RUNID) ==="
for r in 0 1 2 3; do
  f="$OUT/$NAME-rank$r-$RUNID.log"
  echo "-- rank$r: $(grep -cE 'WRONG' "$f" 2>/dev/null) wrong, $(tail -1 "$f" 2>/dev/null)"
done
grep -h "skew_tolerated" "$OUT/$NAME-rank*-$RUNID.log" 2>/dev/null | head -4
