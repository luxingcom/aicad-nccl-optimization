#!/bin/bash
# run_reg.sh <name> <probe args...> — 在已起的 s2-rank* 容器上并行跑一轮 probe
# 纪律: 跑前 pkill 清僵尸(docker exec 不传播 timeout 信号), 跑后再 pkill; 全程 timeout 包裹
# env 透传: 前缀 AR2_ENV="A=1 B=2" (容器内 export)
set -u
NAME=${1:?run-name}; shift
declare -A RANK_HOST=( [0]="dgxspark01" [1]="dgxspark02" [2]="dgxspark04" [3]="dgxspark03" )
PEERS="192.168.5.186,192.168.5.187,192.168.5.189,192.168.5.188"
OUT=~/sparkring-kit/s2/results; mkdir -p "$OUT"; RUNID=$(date +%H%M%S)
AR2_ENV=${AR2_ENV:-}
TMO=${TMO:-420}

for r in 0 1 2 3; do
  h="${RANK_HOST[$r]}"
  PRE="pkill -9 ar2_probe 2>/dev/null; sleep 0.2;"
  RUN="export $AR2_ENV; /src/build-local/ar2_probe --rank $r --peers $PEERS --port 9500 $*"
  if [ "$h" = dgxspark01 ]; then
    ( timeout $TMO docker exec s2-rank0 bash -c "$PRE $RUN" > "$OUT/$NAME-rank$r-$RUNID.log" 2>&1; \
      docker exec s2-rank0 pkill -9 ar2_probe 2>/dev/null ) &
  else
    ( timeout $TMO ssh -o BatchMode=yes "$h" "docker exec s2-rank$r bash -c '$PRE $RUN'" > "$OUT/$NAME-rank$r-$RUNID.log" 2>&1; \
      timeout 20 ssh -o BatchMode=yes "$h" "docker exec s2-rank$r pkill -9 ar2_probe 2>/dev/null" ) &
  fi
done
wait
echo "=== $NAME (RUNID=$RUNID) ==="
for r in 0 1 2 3; do
  f="$OUT/$NAME-rank$r-$RUNID.log"
  echo "-- rank$r: $(grep -cE '\[check\].*WRONG' "$f" 2>/dev/null || echo 0) wrong-data, $(grep -cE 'kernel err|abort|rc=-[0-9]' "$f" 2>/dev/null || echo 0) err-lines; $(tail -1 "$f" 2>/dev/null)"
done
grep -h "skew_tolerated" "$OUT/$NAME-rank*-$RUNID.log" 2>/dev/null && echo "(skew 计数如上)" || echo "(无偏斜命中)"
