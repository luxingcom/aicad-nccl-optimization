# FINALBASE 生产性能基线补测记录 (Rex/SRE 2026-08-17)

## 运行参数 (与 v2 定版 32/32 同参, 保证可比)
- 脚本: /opt/aicad-prod/bench_v2.py (修复版 f72e9e84)
- endpoint: http://<LAN-IP>:8001/v1 (deepseek-v4-flash-0731)
- run_type=both, concurrency=1,2,4,6, task=coding,json,prose, input=512, output=4096
- prefix=512,2048,8192,32768,131076, rounds=3, seed=20260816, cooldown=30s, request-timeout=1800
- 数据目录: /opt/aicad-prod/verification-logs/FINALBASE_20260817_042646/
  summary_v2.json / manifest_v2.json / rows_v2.csv / bench_v2.json / monitor_v2.log / precheck_v2.json
  + 运行日志 FINALBASE_20260817_042646_run.log

## 结果摘要
- n_tiers=32 (DE 12 + PR 20), 全部 ok_rate=1.0, 312/312 requests ok, 0 reject / 0 model_error
- 总耗时 7025.3s (~1h57m), start 04:26:55Z → end 06:24:00Z
- precheck: running=0.0 running_zero=True dspark_start=713.0
- postcheck: 四机 GPU 回落 0%, vllm-tp4-rank0-3 healthy (Up 14h+), 无 bench 残留, endpoint 正常

## 关键指标 (p50)
- DE decode_tps: c1 coding 98.4/json 100.8/prose 51.4; c2 69.4/72.6/42.5; c4 51.6/53.7/30.8; c6 35.9/37.2/25.0
- DE ttft_s: c1 0.38; c2 0.56; c4 1.01; c6 1.32
- PR prefill_tps: pre512 c1 1569.6→c6 404.6; pre2048 2255.8→517.1; pre8192 2308.5→630.4; pre32768 2353.3→681.6; pre131076 2157.2→626.9
- PR ttft_s: pre512 c1 0.28; pre131076 c1 53.5 / c6 183.8

## 可比性说明
- 与 v2 定版 (nccl-benchmark-v2-final-qa-2026-08-16.md, 32/32) 同参同模型; 生产库 2be94172 未变。
- 本补测确认生产终态基线 (供 Tessa 判读定版最终基线文档 nccl-final-performance-baseline-2026-08-17.md)。
