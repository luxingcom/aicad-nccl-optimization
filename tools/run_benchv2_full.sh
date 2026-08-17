#!/bin/bash
# BenchV2 全矩阵后台启动（team-lead 最终命令，含 --precheck）
set -u
EP=http://<LAN-IP>:8001/v1
KEY=c3b4<REDACTED>4594
mkdir -p /opt/aicad-prod/verification-logs
TS=$(date +%Y%m%d_%H%M%S)
OUT=/opt/aicad-prod/verification-logs/BENCHV2_${TS}
echo "${OUT}" > /tmp/benchv2_out_path.txt
nohup python3 /opt/aicad-prod/bench_v2.py \
  --endpoint ${EP} \
  --key ${KEY} \
  --model deepseek-v4-flash-0731 \
  --run-type both \
  --concurrency 1,2,4,6 \
  --task-type coding,json,prose \
  --input-len 512 --output-len 4096 \
  --prefix-len 512,2048,8192,32768,131076 \
  --rounds 3 --random-seed 20260816 \
  --cooldown 30 --request-timeout 1800 \
  --monitor-interval 2 \
  --precheck \
  --out ${OUT} > ${OUT}_run.log 2>&1 &
echo "PID=$!"
sleep 3
echo "STARTED"
