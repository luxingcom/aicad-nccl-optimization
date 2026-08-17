# BenchV2 最终执行命令（代跑方专用）— QA 提供

**日期**：2026-08-16 13:30 (UTC+8)
**提供**：Tessa（QA / Testing Expert）
**前置确认**（team-lead 已确认）：2hop-s1 已清（kill 4020321 + 四机容器删除）、四机 healthy、running==0、8001 正常
**工具**：/opt/aicad-prod/bench_v2.py（md5 6ed8ce93db5a2c95a4cbd8a20a42ebb6）

> 命令在 <node1> 上以 <svc-user> 执行。`<KEY>` 已内嵌，勿外发。

---

## 0. 环境常量

```bash
EP=http://<LAN-IP>:8001/v1
META=http://<LAN-IP>:8001   # vLLM /metrics 在根路径（不带 /v1）
KEY=c3b4<REDACTED>4594
TS=$(date +%Y%m%d_%H%M%S)
OUT=/opt/aicad-prod/verification-logs/BENCHV2_${TS}
echo "BENCHV2_OUT=${OUT}"   # 记录此路径回传
```

---

## 1. Precheck P1-P6（逐项执行，结果回传 QA 确认）

```bash
# P1 四机 healthy —— 期望 4 容器均 Up (healthy)
for h in <node1> <node2> <node3> <node4>; do
  echo "== $h =="; ssh $h "docker ps --filter name=vllm-tp4-rank --format '{{.Names}} {{.Status}}'"
done

# P2 无 2hop/bench 残留 —— 期望无输出
ps aux | grep -E "twohop|nccl_scan|bench_v2" | grep -v grep
docker ps -a | grep 2hop

# P3 四机 GPU util —— 期望全部 0%（vLLM Worker 显存占用属正常）
for h in <node1> <node2> <node3> <node4>; do
  echo -n "$h: "; ssh $h 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | head -1'
done

# P4 running==0 —— 期望 0.0（注意：/metrics 在根路径 META，不带 /v1）
curl -s ${META}/metrics -H "Authorization: Bearer ${KEY}" | grep '^vllm:num_requests_running'

# P5 模型可达 —— 期望 200 + deepseek-v4-flash-0731
curl -s ${EP}/models -H "Authorization: Bearer ${KEY}" | head -c 300; echo

# P6 dspark counter 起始值 —— 记录全部 spec_decode_* 值（/metrics 在根路径 META）
curl -s ${META}/metrics -H "Authorization: Bearer ${KEY}" | \
  grep -E '^vllm:spec_decode_(num_drafts|num_draft_tokens|num_accepted_tokens)' 
```

---

## 2. 全矩阵执行（32 档，一条命令）

```bash
TS=$(date +%Y%m%d_%H%M%S)
OUT=/opt/aicad-prod/verification-logs/BENCHV2_${TS}
echo "BENCHV2_OUT=${OUT}"

python3 /opt/aicad-prod/bench_v2.py \
  --endpoint http://<LAN-IP>:8001/v1 \
  --key c3b4<REDACTED>4594 \
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
  --out ${OUT} 2>&1 | tee ${OUT}_run.log
```

**预期行为**（SRE dry-run 已验证）：
- 顺序按方案 §7.1：C1(DE3+PR5) → C2 → C4 → C6，档间冷却 30s
- 每档独立 monitor（running==C 判据，5s/2s 采样）+ dspark counter Δ
- DE 档 ignore_eos 强制满长 4096；PR 档 max_tokens=1 纯 prefill
- 预计总时长 105–135 min；131K PR 在 C6 可能显著变慢（单请求 >600s 会记录并继续，不中断）

**可选 dry-run 预检**（若 bench_v2.py 支持 `--dry-run`；不支持则跳过，SRE 已验证全矩阵）：
```bash
python3 /opt/aicad-prod/bench_v2.py --endpoint http://<LAN-IP>:8001/v1 \
  --key ${KEY} --model deepseek-v4-flash-0731 --run-type both \
  --concurrency 1,2,4,6 --task-type coding,json,prose \
  --input-len 512 --output-len 4096 --prefix-len 512,2048,8192,32768,131076 \
  --rounds 3 --random-seed 20260816 --dry-run
```

---

## 3. Postcheck（执行完成后）

```bash
# GPU 回落 —— 期望全部 0%
for h in <node1> <node2> <node3> <node4>; do
  echo -n "$h: "; ssh $h 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader | head -1'
done

# running==0 —— 期望 0.0
curl -s ${EP}/metrics -H "Authorization: Bearer ${KEY}" | grep '^vllm:num_requests_running'

# 无残留 bench 进程 —— 期望无输出
ps aux | grep -E "bench_v2|twohop" | grep -v grep

# 落盘校验 —— 期望 summary 32 个（12 DE + 20 PR）+ manifest 1 个
OUT=$(ls -dt /opt/aicad-prod/verification-logs/BENCHV2_* | head -1)
echo "OUT=${OUT}"
find ${OUT} -name "summary_*.json" | wc -l
find ${OUT} -name "manifest_*.json" | wc -l
ls ${OUT}
```

---

## 4. 代跑方回传 QA 清单

1. precheck P1-P6 逐项结果
2. `BENCHV2_OUT` 路径
3. 每档目录内容确认（rows+summary+monitor+bench+manifest+precheck）
4. summary 数量（期望 32）+ manifest 数量（期望 1）
5. 任何异常（超时、monitor 未达 C、引擎事件、run.log 尾部）

QA 收到后：校验 → 判读（v1 锚定对照 / dspark 接受率 / 并发放大趋势）→ 出 QA 判读报告回传。
