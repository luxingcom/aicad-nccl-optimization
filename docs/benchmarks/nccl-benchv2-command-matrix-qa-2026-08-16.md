# BenchV2 执行命令矩阵（代跑模式）— QA 提供

**日期**：2026-08-16 13:10 (UTC+8)
**提供**：Tessa（QA / Testing Expert）
**用途**：交代跑方（Rex/team-lead/SRE）在工具就绪后按此矩阵执行。CLI 形态以 Rex `bench_v2.py` 实际参数为准；若参数名与下表占位不同，按语义映射（矩阵行是权威）。

---

## 0. 执行前 precheck（代跑方执行，结果回传 QA 确认）

| # | 检查 | 命令（参考） | 通过判据 |
|---|---|---|---|
| P1 | 四机 healthy | `for h in <node1> 02 03 04; do ssh $h "docker ps --filter name=vllm-tp4-rank --format '{{.Names}} {{.Status}}'" ; done` | 4 容器均 Up (healthy) |
| P2 | 2hop 残留已清 | `ps aux \| grep '[t]wohop_bench.py'`；`docker ps -a \| grep 2hop` | 无 python 主进程；无 2hop-s1 容器（或已 stop） |
| P3 | GPU 空闲 | `for h in <node1> 02 03 04; do ssh $h 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader'; done` | 全部 0%（允许 vLLM 容器占用显存但 util≈0） |
| P4 | running==0 | `curl -s <EP>/metrics -H "Authorization: Bearer <KEY>" \| grep '^vllm:num_requests_running'` | 0.0 |
| P5 | 模型可达 | `curl -s <EP>/models -H "Authorization: Bearer <KEY>"` | 200，deepseek-v4-flash-0731 |
| P6 | dspark 计数器起始值 | `curl -s <EP>/metrics -H "Authorization: Bearer <KEY>" \| grep -E '^vllm:spec_decode_(num_drafts|num_draft_tokens|num_accepted_tokens)(_total)?\{'` | 记录 4 个 counter 值到 manifest |

EP=http://<LAN-IP>:8001/v1；KEY=c3b4<REDACTED>4594

---

## 1. 统一参数（所有档）

| 参数 | 值 |
|---|---|
| endpoint | http://<LAN-IP>:8001/v1 |
| key | c3b4<REDACTED>4594 |
| model | deepseek-v4-flash-0731 |
| engine | threads（与 v1 一致；若 runner 仅支持 asyncio 也可，标注 engine 即可，不与 v1 直比） |
| rounds | 3 |
| temperature | 0.6（runner 默认） |
| 落盘根 | /opt/aicad-prod/verification-logs/BENCHV2_<YYYYMMDD_HHMMSS>/<档名>/ |

---

## 2. 全量命令矩阵（32 档）

### 2.1 DE 文本吞吐（12 档）—— `--max-tokens 4096`（如 runner 支持 `--ignore-eos` 则加，否则按默认 EOS 记录实际 completion）

| 序号 | 档名 | conc | task | ctx(输入) | max_tokens | ignore_eos | 输出 |
|---|---|---|---|---|---|---|---|
| D1 | DE_C1_coding | 1 | coding | 512 | 4096 | 建议 true | rows+summary+monitor |
| D2 | DE_C1_json | 1 | json | 512 | 4096 | 建议 true | 同上 |
| D3 | DE_C1_prose | 1 | prose | 512 | 4096 | 建议 true | 同上 |
| D4 | DE_C2_coding | 2 | coding | 512 | 4096 | 建议 true | 同上 |
| D5 | DE_C2_json | 2 | json | 512 | 4096 | 建议 true | 同上 |
| D6 | DE_C2_prose | 2 | prose | 512 | 4096 | 建议 true | 同上 |
| D7 | DE_C4_coding | 4 | coding | 512 | 4096 | 建议 true | 同上 |
| D8 | DE_C4_json | 4 | json | 512 | 4096 | 建议 true | 同上 |
| D9 | DE_C4_prose | 4 | prose | 512 | 4096 | 建议 true | 同上 |
| D10 | DE_C6_coding | 6 | coding | 512 | 4096 | 建议 true | 同上 |
| D11 | DE_C6_json | 6 | json | 512 | 4096 | 建议 true | 同上 |
| D12 | DE_C6_prose | 6 | prose | 512 | 4096 | 建议 true | 同上 |

### 2.2 PR 吞吐（20 档）—— `--max-tokens 1`（纯 prefill）

| 序号 | 档名 | conc | task | 前缀长度(ctx) | max_tokens | 输出 |
|---|---|---|---|---|---|---|
| P1 | PR_C1_L512 | 1 | coding（或 plain） | 512 | 1 | rows+summary+monitor |
| P2 | PR_C1_L2048 | 1 | coding（或 plain） | 2048 | 1 | 同上 |
| P3 | PR_C1_L8192 | 1 | coding（或 plain） | 8192 | 1 | 同上 |
| P4 | PR_C1_L32768 | 1 | coding（或 plain） | 32768 | 1 | 同上 |
| P5 | PR_C1_L131076 | 1 | coding（或 plain） | 131076 | 1 | 同上 |
| P6 | PR_C2_L512 | 2 | coding（或 plain） | 512 | 1 | 同上 |
| P7 | PR_C2_L2048 | 2 | coding（或 plain） | 2048 | 1 | 同上 |
| P8 | PR_C2_L8192 | 2 | coding（或 plain） | 8192 | 1 | 同上 |
| P9 | PR_C2_L32768 | 2 | coding（或 plain） | 32768 | 1 | 同上 |
| P10 | PR_C2_L131076 | 2 | coding（或 plain） | 131076 | 1 | 同上 |
| P11 | PR_C4_L512 | 4 | coding（或 plain） | 512 | 1 | 同上 |
| P12 | PR_C4_L2048 | 4 | coding（或 plain） | 2048 | 1 | 同上 |
| P13 | PR_C4_L8192 | 4 | coding（或 plain） | 8192 | 1 | 同上 |
| P14 | PR_C4_L32768 | 4 | coding（或 plain） | 32768 | 1 | 同上 |
| P15 | PR_C4_L131076 | 4 | coding（或 plain） | 131076 | 1 | 同上 |
| P16 | PR_C6_L512 | 6 | coding（或 plain） | 512 | 1 | 同上 |
| P17 | PR_C6_L2048 | 6 | coding（或 plain） | 2048 | 1 | 同上 |
| P18 | PR_C6_L8192 | 6 | coding（或 plain） | 8192 | 1 | 同上 |
| P19 | PR_C6_L32768 | 6 | coding（或 plain） | 32768 | 1 | 同上 |
| P20 | PR_C6_L131076 | 6 | coding（或 plain） | 131076 | 1 | 同上 |

---

## 3. 执行顺序与隔离

```
[P1-P6 precheck] → 记录 dspark 计数器起始值
C1 段: D1 → D2 → D3 → P1 → P2 → P3 → P4 → P5   （monitor: running==1；波间边界 running=0 可容忍）
[冷却 30s: running 回落 0 且稳定]
C2 段: D4 → D5 → D6 → P6 → P7 → P8 → P9 → P10  （monitor: running==2）
[冷却 30s]
C4 段: D7 → D8 → D9 → P11 → P12 → P13 → P14 → P15 （monitor: running==4）
[冷却 30s]
C6 段: D10 → D11 → D12 → P16 → P17 → P18 → P19 → P20 （monitor: running==6；引擎容量上限，波动记录不判失败）
[冷却 30s] → [postcheck: GPU 0% / running==0] → manifest.json 汇总
```

**monitor 判据**：每 5s 采样 `vllm:num_requests_running` 写入 monitor_<档>.log；档窗口 = running 达到 C 至回落；波间边界波动记录不判失败。

---

## 4. 代跑方需回传 QA 的内容

1. 每档目录：`rows_*.csv` + `summary_*.json` + `monitor_*.log` + `bench.log`（+ precheck.log）
2. precheck 结果（P1-P6 逐项）
3. manifest.json（批次时间戳、每档 start/end/elapsed、dspark 计数器起始与结束值、环境快照）
4. 任何异常（超时、引擎重启、监控未达 C 档）

---

## 5. 备注

- 若 runner 尚未支持 `--max-tokens`/`--ignore-eos`，可用既有 `bench_prefill_decode_async.py` + 源码注入 wrapper（v1 已验证可行），QA 可提供最小 wrapper 规范。
- 131K PR（P5/P10/P15/P20）长 prefill：单请求 TTFT ~52s；C6 下 6×131K 大消息 allreduce 可能显著变慢，预留超时余量（单请求 >600s 记录并继续）。
- 本矩阵为权威参数表；CLI 具体拼写以 Rex runner 实际参数为准，语义映射见本表。
