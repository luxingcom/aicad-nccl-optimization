#!/bin/bash
# s4_bench.sh — W7 S4 NCCL allreduce bench (B1 口径: nccl-tests all_reduce, 4-rank, in-place, avg)
# 拓扑: 4 节点 x 每节点 1 进程(GB10 x1/节点) = 4 rank 跨节点, RoCE 数据面
# 用法(在 .186 head 上):
#   bash /home/liux***ya/w6-kit/s4_bench.sh timed    # 计时轮(无 NCCL_DEBUG)
#   bash /home/liux***ya/w6-kit/s4_bench.sh verify   # 验证轮(64KB, NCCL_DEBUG=INFO, 出 NET/IB 行)
# 前置: 四机 w6-kit 就位; 免密 ssh 192.168.5.186-189; 宿主机 mpirun(OpenMPI 4.1.6)
set -u
KIT=/home/liux***ya/w6-kit
PERF=$KIT/s4_build/all_reduce_perf
RING=/opt/nccl-ringonly
PIN=$KIT/libncclpin.so

# 生产同款(=w6_env.txt NCCL 家族, 计时轮关 DEBUG 以免拖累口径)
export NCCL_ALGO=RING
export NCCL_NET=IB
export NCCL_IB_HCA="rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1"
export NCCL_IB_GID_INDEX=3
export NCCL_IB_TOS=46
export NCCL_IB_MERGE_NICS=0
export NCCL_IB_SUBNET_AWARE_ROUTING=1
export NCCL_IB_TIMEOUT=1000
export NCCL_IB_RETRY_CNT=7
export NCCL_CUMEM_HOST_ENABLE=0
export NCCL_CROSS_NIC=1
export NCCL_MIN_NCHANNELS=4
export NCCL_MAX_NCHANNELS=4
export NCCL_TUNER_THRESHOLD=40960
export NCCL_IGNORE_CPU_AFFINITY=1
export NCCL_BUFFSIZE=8388608
export NCCL_NET_PLUGIN=none
export NCCL_SOCKET_IFNAME=enP7s7
export GLOO_SOCKET_IFNAME=enP7s7
# 双库同生产: pin 库 + ringonly(带引号整体 preload)
export LD_PRELOAD="$PIN $RING/libnccl.so.2"
export LD_LIBRARY_PATH="$RING:/usr/local/cuda/targets/sbsa-linux/lib:${LD_LIBRARY_PATH:-}"
export CUDA_DEVICE_ORDER=PCI_BUS_ID

# mpirun 公共段: 4 rank 每节点 1 进程, OOB/bootstrap 走管理网 enP7s7
MPIRUN="mpirun --allow-run-as-root -np 4 --hostfile $KIT/s4_hostfile --map-by node"
MPIRUN="$MPIRUN --mca btl_tcp_if_include enP7s7 --mca oob_tcp_if_include enP7s7"
XVARS="-x LD_PRELOAD -x LD_LIBRARY_PATH -x NCCL_ALGO -x NCCL_NET -x NCCL_IB_HCA \
-x NCCL_IB_GID_INDEX -x NCCL_IB_TOS -x NCCL_IB_MERGE_NICS -x NCCL_IB_SUBNET_AWARE_ROUTING \
-x NCCL_IB_TIMEOUT -x NCCL_IB_RETRY_CNT -x NCCL_CUMEM_HOST_ENABLE -x NCCL_CROSS_NIC \
-x NCCL_MIN_NCHANNELS -x NCCL_MAX_NCHANNELS -x NCCL_TUNER_THRESHOLD \
-x NCCL_IGNORE_CPU_AFFINITY -x NCCL_BUFFSIZE -x NCCL_NET_PLUGIN \
-x NCCL_SOCKET_IFNAME -x CUDA_DEVICE_ORDER"

MODE=${1:-timed}

# ── 2026-09-21 GID 洞预检：本工具硬编码 NCCL_IB_GID_INDEX=3，断电后 GID 表出洞
# （v2 落 idx4、idx3 空）时 modify_qp RTR 必挂（errno 61 "local GID ::"）——那是
# fabric 病不是本工具病。先报洞再跑，省一轮误诊。修复见 FABRIC-GID-REPAIR-RUNBOOK.md。
gid_hole_audit() {
  local bad=0 h holes
  for h in 186 187 188 189; do
    holes=$(ssh -o ConnectTimeout=8 -o BatchMode=yes 192.168.5.$h '
      for c in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
        [ -d /sys/class/infiniband/$c ] || continue
        [ "$(cat /sys/class/infiniband/$c/ports/1/gid_attrs/types/3 2>/dev/null)" = "RoCE v2" ] || echo $c
      done' 2>/dev/null | tr '\n' ' ')
    if [ -n "$holes" ]; then
      echo "[!!] 192.168.5.$h GID 洞(idx3): $holes"
      bad=1
    fi
  done
  if [ $bad -eq 1 ]; then
    echo "[!!] 修复（每洞口一次 IP 环回；详见 ~/w6-kit/FABRIC-GID-REPAIR-RUNBOOK.md §2）:"
    echo "[!!]   ssh <host> 'sudo -S sh -c \"ip addr del <IP>/<前缀> dev <netdev> && ip addr add <IP>/<前缀> dev <netdev>\"'"
    echo "[!!] 修完重跑本审计直至零洞，再跑 verify。"
    return 1
  fi
  echo "[ok] 四机 16 口 idx3 均有 RoCE v2 GID（无洞）"
}
gid_hole_audit || exit 9

if [ "$MODE" = "verify" ]; then
  # T3 验证轮: 64KB 单档, INFO 看传输行(S3 证据补强: NET/IB 四口 RoCE)
  echo "=== VERIFY RUN: 64KB, NCCL_DEBUG=INFO (expect NET/IB vectors on RoCE) ==="
  $MPIRUN $XVARS -x NCCL_DEBUG=INFO -x NCCL_DEBUG_SUBSYS=INIT,NET \
    $PERF -b 65536 -e 65536 -i 65536 -g 1 -c -w 5 -n 20 \
    2>&1 | tee $KIT/s4_verify_$(date +%m%d_%H%M%S).log
  echo "=== done. grep anchors: 'NET/IB' 'rocep' 'Via' ==="
  exit 0
fi

# ---- 计时轮: 六档 size(字节) ----
SIZES=(8 64 512 4096 65536 1048576)
RESULT=$KIT/s4_result_$(date +%m%d_%H%M%S).csv
echo "size_bytes,avg_us,min_us,max_us,alg_bw_GBps" > $RESULT
unset NCCL_DEBUG NCCL_DEBUG_SUBSYS   # 计时轮强制无 DEBUG

for S in "${SIZES[@]}"; do
  if [ $S -ge 1048576 ]; then W=10; N=50; else W=20; N=100; fi
  echo "=== size=$S warmup=$W iters=$N ==="
  # nccl-tests 自身输出 per-rank min/avg/max(amortized time), 取聚合尾部数据行
  OUT=$($MPIRUN $XVARS $PERF -b $S -e $S -i $S -g 1 -c -w $W -n $N 2>/dev/null)
  echo "$OUT" | tail -10
  # in-place(-c) 输出两块: out-of-place + in-place; 取最后数据行(in-place)
  PARSED=$(echo "$OUT" | awk '$1 ~ /^[0-9]+$/ && NF>=8 {line=$0; n=split($0,a," ")} END{print line}')
  if [ -z "$PARSED" ]; then echo "PARSE_FAIL size=$S"; echo "$S,NA,NA,NA,NA" >> $RESULT; continue; fi
  # 列序(实测): size count type redop root | time algbw busbw #wrong | time algbw busbw #wrong
  # 前 5 列 out-of-place, 后 4 列 in-place(-c); 取 in-place: time=$10 algbw=$11 busbw=$12
  PARSED=$(echo "$OUT" | awk '$1 ~ /^[0-9]+$/ && NF>=13 {line=$0} END{print line}')
  if [ -z "$PARSED" ]; then echo "PARSE_FAIL size=$S"; echo "$S,NA,NA,NA,NA" >> $RESULT; continue; fi
  TIME_US=$(echo "$PARSED" | awk '{print $10}')
  ALGBW=$(echo "$PARSED" | awk '{print $11}')
  BUSBW=$(echo "$PARSED" | awk '{print $12}')
  # min/max: nccl-tests 不直接给跨 rank min/max; 用同档 3 连跑取 min/avg/max 近似
  T2=$($MPIRUN $XVARS $PERF -b $S -e $S -i $S -g 1 -c -w 3 -n $N 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && NF>=13 {t=$10} END{print t}')
  T3=$($MPIRUN $XVARS $PERF -b $S -e $S -i $S -g 1 -c -w 3 -n $N 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && NF>=13 {t=$10} END{print t}')
  MIN=$(printf '%s\n%s\n%s\n' "$TIME_US" "$T2" "$T3" | sort -g | head -1)
  MAX=$(printf '%s\n%s\n%s\n' "$TIME_US" "$T2" "$T3" | sort -g | tail -1)
  echo "size=$S time_us=$TIME_US algbw=$ALGBW busbw=$BUSBW min3=$MIN max3=$MAX"
  echo "$S,$TIME_US,$MIN,$MAX,$ALGBW" >> $RESULT
done
echo "RESULT_CSV: $RESULT"
