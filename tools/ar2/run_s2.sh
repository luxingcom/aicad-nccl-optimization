#!/bin/bash
# run_s2.sh <mode:m1|layer|kill> — S2 ar2 四机窗口 runbook (W1 轮实战验证的命令固化)
# 纪律: ①起容器 ②容器内 pkill 清僵尸(docker exec 不传播 timeout 信号!) ③并行跑 ④pkill+rm 清理
set -u
MODE=${1:?m1|layer|kill}
IMG="192.0.2.187:5000/vllm/vllm-openai:LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring-baked"
declare -A RANK_HOST=( [0]="dgxspark01" [1]="dgxspark02" [2]="dgxspark04" [3]="dgxspark03" )
PEERS="192.0.2.186,192.0.2.187,192.0.2.189,192.0.2.188"
OUT=~/sparkring-kit/s2/results; mkdir -p "$OUT"; RUNID=$(date +%H%M%S)

up() {
  for r in 0 1 2 3; do
    h="${RANK_HOST[$r]}"
    if [ "$h" = dgxspark01 ]; then
      docker rm -f s2-rank$r >/dev/null 2>&1
      docker run -d --name s2-rank$r --restart no --network host --ipc=host --privileged --gpus all \
        -v /home/<user>/sparkring-kit/s2:/src:ro --entrypoint /bin/bash "$IMG" -c 'sleep 3600' >/dev/null
    else
      timeout 60 ssh -o BatchMode=yes "$h" "docker rm -f s2-rank$r >/dev/null 2>&1; docker run -d --name s2-rank$r --restart no --network host --ipc=host --privileged --gpus all -v /home/<user>/sparkring-kit/s2:/src:ro --entrypoint /bin/bash $IMG -c 'sleep 3600' >/dev/null"
    fi
  done
  sleep 2
}
down() {
  for r in 0 1 2 3; do
    h="${RANK_HOST[$r]}"
    if [ "$h" = dgxspark01 ]; then docker exec s2-rank$r pkill -9 ar2_probe 2>/dev/null; docker rm -f s2-rank$r >/dev/null 2>&1
    else timeout 30 ssh -o BatchMode=yes "$h" "docker exec s2-rank$r pkill -9 ar2_probe 2>/dev/null; docker rm -f s2-rank$r >/dev/null 2>&1"; fi
  done
}
case "$MODE" in
m1|layer)
  ARGS="--mode $MODE --iters 200 --warmup 20"; [ "$MODE" = m1 ] && ARGS="$ARGS --sizes 1024,4096,16384,32768,65536"
  up
  for r in 0 1 2 3; do
    h="${RANK_HOST[$r]}"
    if [ "$h" = dgxspark01 ]; then
      ( timeout 250 docker exec s2-rank0 /src/build-local/ar2_probe --rank 0 --peers $PEERS --port 9500 $ARGS > "$OUT/$MODE-rank0-$RUNID.log" 2>&1 ) &
    else
      ( timeout 250 ssh -o BatchMode=yes "$h" "docker exec s2-rank$r /src/build-local/ar2_probe --rank $r --peers $PEERS --port 9500 $ARGS" > "$OUT/$MODE-rank$r-$RUNID.log" 2>&1 ) &
    fi
  done
  wait; grep -hE "^\[ar2\]" "$OUT/$MODE-rank0-$RUNID.log"
  ;;
kill)
  up
  for r in 0 1 2 3; do
    h="${RANK_HOST[$r]}"
    EXTRA=""; [ "$r" = 1 ] && EXTRA="--die-after 30"
    if [ "$h" = dgxspark01 ]; then
      ( timeout 120 docker exec s2-rank0 /src/build-local/ar2_probe --rank 0 --peers $PEERS --port 9500 --mode m1 --sizes 4096 --iters 200 --warmup 20 > "$OUT/kill-rank0-$RUNID.log" 2>&1 ) &
    else
      ( timeout 120 ssh -o BatchMode=yes "$h" "docker exec s2-rank$r /src/build-local/ar2_probe --rank $r --peers $PEERS --port 9500 --mode m1 --sizes 4096 --iters 200 --warmup 20 $EXTRA" > "$OUT/kill-rank$r-$RUNID.log" 2>&1 ) &
    fi
  done
  wait; echo "expect: r1 exit 9 ~1s; r0/r2/r3 rc=1 within ~6s (abort cascade)"
  ;;
esac
down
echo "RUNID=$RUNID (cleaned)"
