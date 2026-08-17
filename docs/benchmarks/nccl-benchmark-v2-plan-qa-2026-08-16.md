# v2 基准测试方案（BenchV2）— QA 编制

**日期**：2026-08-16 12:45 (UTC+8)
**编制**：Tessa（QA / Testing Expert，工程保障团队）
**被测对象**：DGX Spark 四机环网 TP4 vLLM（DeepSeek V4 Flash 0731），NCCL 2.30.7 ring-only（库 2be94172：v1 环邻过滤 + v4 硬编码映射 + enqueue 双带 tuner）
**端点**：http://<LAN-IP>:8001/v1（key 已配置）
**状态**：📋 **方案待 team-lead 批准 → 工具扩展（Rex）→ 执行**

---

## 0. TL;DR（方案摘要）

- **测试矩阵**：并发档 C1/C2/C4/C6 × 两类任务（DE 文本吞吐 3 种输出类型 + PR 前缀 5 档），共 **32 个测试组合**。
- **DE 文本吞吐**：输入限制 512 tokens，输出限制 4096 tokens，coding/json/prose 三种输出类型各自独立测量 decode 吞吐（`--max-tokens 4096`）。
- **PR 吞吐**：随机前缀 512/2048/8192/32768/131076，输出限制 1 token（纯 prefill 测吞吐，`--max-tokens 1`）。
- **dspark 接受率**：生产 vLLM 运行 `--speculative-config {"method":"dspark", ...}`（num_speculative_tokens=5），`/metrics` 已暴露 `vllm:spec_decode_num_drafts_total` / `spec_decode_num_draft_tokens_total` / `spec_decode_num_accepted_tokens_total` / 每位置 accepted 计数 → **可直接测「投机解码 token 接受率」**（primary 定义，详见 §3.3）；同时统计「请求接受率/成功率」（网络层拒绝 vs 模型层错误）作为 dspark 指标的第二分量（请求级成功率）。
- **隔离与时间对齐**：并发档之间、任务类型之间串行；每档 monitor 纯净窗口（running==C）；档间冷却（running 回落 0 再起下一档）；同一环境状态批次内完成，记录每档时间戳与总耗时。
- **工具差距**：现有 `bench_prefill_decode_async.py` 不支持输出长度/前缀长度的 CLI 覆盖、不接受率分层统计、不采样 dspark 指标 → **需要 Rex 开发 runner 扩展**（§6 清单）。
- **预估总时长**：全矩阵约 **105–135 分钟**（不含冷却/复查），执行窗口安排见 §7。

---

## 1. 环境确认（2026-08-16 12:43 实测）

| 检查项 | 结果 |
|---|---|
| 端点 /v1/models | HTTP 200，`deepseek-v4-flash-0731`（max_model_len 400000）✅ |
| 四机 healthy | <node1>(186 rank0) / 02(187 rank1) / 04(189 rank2) / 03(188 rank3)，`docker ps` 均 Up（healthy）✅ |
| GPU 状态 | 四机 vLLM 容器显存 78.4GB/节点；**但 <node1> GPU util 92%（2hop-s1 bench 占用 469MiB + CPU 99%）**，02/03/04 util 0% ⚠️ |
| vLLM 启动参数 | `--max-num-seqs 6 --max-num-batched-tokens 4096 --long-prefill-token-threshold 1024 --scheduling-policy priority --speculative-config {"method":"dspark","num_speculative_tokens":5,"num_speculative_tokens_per_batch_size":[[1,1,5],[2,4,4],[5,6,3]]} --enable-prefix-caching` |
| NCCL | `NCCL_ALGO=RING`、`NCCL_NET=IB`、`NCCL_MIN_NCHANNELS=4`、`NCCL_MAX_NCHANNELS=16`、`NCCL_TUNER_THRESHOLD=40960`、ring-only 库（LD_PRELOAD /opt/nccl-ringonly/libnccl.so.2） |
| /metrics | `vllm:num_requests_running` 现为 0.0（空闲）✅；**dspark spec-decode 计数器存在且可读**（当前为 0 累计，测试时随请求增长）✅ |
| 干扰 ⚠️ | **2hop-s1 bench 仍在运行**（python 4020321，11:07 起，rank0 CPU 99.3%、469MiB GPU；<node1> GPU util 92%）。**执行前必须先停掉该 bench（属 SRE/2hop 测试方），否则 rank0 结果被污染**（见 §8 风险 5） |

---

## 2. 测试矩阵（完整）

### 2.1 符号与统一参数（可比性）

| 参数 | 值 | 说明 |
|---|---|---|
| engine | `threads` | 与 v1 体系一致（v1 全部 threads） |
| rounds（波数） | 3 | 每波 conc 并发在飞；p50 取全部成功请求 |
| temperature | 0.6 | 脚本默认，v1 同参 |
| seed / 采样 | 不固定（随机 uuid 前缀） | 防 prefix-cache，v1 同方法 |
| 输出格式 | rows CSV + summary JSON + monitor.log + bench.log + precheck.log | 每档一目录，含时间戳 |
| 校准 | 每批次一次 tokens/unit 校准 | 随机前缀实际 tokens 以 usage.prompt_tokens 为准 |

### 2.2 矩阵总表（32 组合）

#### 2.2.1 DE 文本吞吐（输出限制 4096，输入 512）— 12 组合

| # | 档位名 | conc | task | ctx(输入) | max_tokens | 测量目标 |
|---|---|---|---|---|---|---|
| D1 | DE_C1_coding | 1 | coding | 512 | 4096 | p50 DE / PR / TTFT |
| D2 | DE_C1_json | 1 | json | 512 | 4096 | 同上 |
| D3 | DE_C1_prose | 1 | prose | 512 | 4096 | 同上 |
| D4 | DE_C2_coding | 2 | coding | 512 | 4096 | 同上 |
| D5 | DE_C2_json | 2 | json | 512 | 4096 | 同上 |
| D6 | DE_C2_prose | 2 | prose | 512 | 4096 | 同上 |
| D7 | DE_C4_coding | 4 | coding | 512 | 4096 | 同上 |
| D8 | DE_C4_json | 4 | json | 512 | 4096 | 同上 |
| D9 | DE_C4_prose | 4 | prose | 512 | 4096 | 同上 |
| D10 | DE_C6_coding | 6 | coding | 512 | 4096 | 同上 |
| D11 | DE_C6_json | 6 | json | 512 | 4096 | 同上 |
| D12 | DE_C6_prose | 6 | prose | 512 | 4096 | 同上 |

#### 2.2.2 PR 吞吐（输出限制 1，纯 prefill）— 20 组合

| # | 档位名 | conc | task | 前缀长度 | max_tokens | 测量目标 |
|---|---|---|---|---|---|---|
| P1 | PR_C1_L512 | 1 | coding* | 512 | 1 | p50 PR / TTFT |
| P2 | PR_C1_L2048 | 1 | coding* | 2048 | 1 | 同上 |
| P3 | PR_C1_L8192 | 1 | coding* | 8192 | 1 | 同上 |
| P4 | PR_C1_L32768 | 1 | coding* | 32768 | 1 | 同上 |
| P5 | PR_C1_L131076 | 1 | coding* | 131076 | 1 | 同上 |
| P6 | PR_C2_L512 | 2 | coding* | 512 | 1 | 同上 |
| P7 | PR_C2_L2048 | 2 | coding* | 2048 | 1 | 同上 |
| P8 | PR_C2_L8192 | 2 | coding* | 8192 | 1 | 同上 |
| P9 | PR_C2_L32768 | 2 | coding* | 32768 | 1 | 同上 |
| P10 | PR_C2_L131076 | 2 | coding* | 131076 | 1 | 同上 |
| P11 | PR_C4_L512 | 4 | coding* | 512 | 1 | 同上 |
| P12 | PR_C4_L2048 | 4 | coding* | 2048 | 1 | 同上 |
| P13 | PR_C4_L8192 | 4 | coding* | 8192 | 1 | 同上 |
| P14 | PR_C4_L32768 | 4 | coding* | 32768 | 1 | 同上 |
| P15 | PR_C4_L131076 | 4 | coding* | 131076 | 1 | 同上 |
| P16 | PR_C6_L512 | 6 | coding* | 512 | 1 | 同上 |
| P17 | PR_C6_L2048 | 6 | coding* | 2048 | 1 | 同上 |
| P18 | PR_C6_L8192 | 6 | coding* | 8192 | 1 | 同上 |
| P19 | PR_C6_L32768 | 6 | coding* | 32768 | 1 | 同上 |
| P20 | PR_C6_L131076 | 6 | coding* | 131076 | 1 | 同上 |

\* PR 任务用 coding 模板（仅作为填充载体；输出 1 token 时任务语义无关紧要，随机 uuid 前缀才是 prefill 主体）。如工具支持 `--task plain`（纯随机前缀无模板），优先用 plain，避免模板 token 混入 prefill 长度口径；否则用 coding 并在结果中标注。

**执行顺序**：DE 全部（D1→D12）→ PR 全部（P1→P20），或按并发档分组（C1: D1-3+P1-5 → C2: D4-6+P6-10 → …）。**推荐按并发档分组**，便于 monitor 纯净窗口判据与档间冷却复用同一环境状态（§5.2）。

---

## 3. 指标定义

### 3.1 单请求级（per-request）

| 指标 | 公式 | 说明 |
|---|---|---|
| **PR（prefill 吞吐）** | `prompt_tokens / TTFT` | TTFT = 首个含 content 的 SSE chunk 到达时间（同 v1 脚本语义） |
| **DE（decode 吞吐）** | `(completion_tokens - 1) / (total_s - ttft_s)` | 减 1 排除 TTFT 那个 token；total = 完成时间 |
| **TTFT** | 首个 content chunk 到达的秒数 | 同 v1 |
| **total_s** | 请求总时长 | 同 v1 |
| **ok / err** | 布尔 + 错误描述 | 现脚本已有 |

### 3.2 批内聚合级（wave/batch）

| 指标 | 公式 | 说明 |
|---|---|---|
| **agg_prefill_tps** | `Σ prompt_tokens / max(TTFT)` | 一波内批吞吐（并发档主要判读指标） |
| **agg_decode_tps** | `Σ (ct-1) / (max(total)-max(ttft))` | 同上 |
| **p50_*** | 全部成功请求的中位数 | 同 v1 summary 语义 |

### 3.3 dspark 接受率（primary 定义：投机解码 token 接受率）

> **假设标注**：用户「dspark 接受率」按生产环境语义判定为 **dspark 投机解码（speculative decoding）的 token 接受率** —— 因为 vLLM 以 `--speculative-config {"method":"dspark",...}` 运行，且 `/metrics` 暴露官方 dspark 计数器。若用户本意是「请求接受率/成功率」，见 §3.4 第二分量，二者都会交付。

采样 `/metrics` 计数器（`vllm:spec_decode_*_total`，Prometheus counter），在**每档测试窗口前后各采样一次**，取差值：

| 指标 | 公式 | 说明 |
|---|---|---|
| **dspark token 接受率** | `Δaccepted_tokens / Δdraft_tokens` | 核心指标；draft=提议 token，accepted=被目标模型接受 |
| **draft 命中分布** | `Δaccepted_tokens_per_pos{position=i} / Δdrafts`（i=0..4） | 每个投机位置接受率，反映 dspark 提议质量 |
| **draft 批量效率** | `Δdrafts / 请求数` 或 `Δdraft_tokens / 请求数` | 每请求平均提议 token 数 |
| **接受率增益** | `DE_measured / DE_no_spec_基线`（可选） | 有 dspark 的实测 DE 与无投机基线对照（若存在同参无投机基线） |

计数器来源（已实测存在）：`vllm:spec_decode_num_drafts_total`、`vllm:spec_decode_num_draft_tokens_total`、`vllm:spec_decode_num_accepted_tokens_total`、`vllm:spec_decode_num_accepted_tokens_per_pos_total{position="0".."4"}`。

**注意**：计数器为引擎全局累计，若档间有残留请求会污染差值 → 依赖 monitor 纯净窗口 + 档间冷却（§5.2）保证每档窗口独占计数。

### 3.4 请求接受率/成功率（second 分量，数据质量门禁）

| 指标 | 公式 | 说明 |
|---|---|---|
| **请求成功率** | `成功响应请求数 / 总请求数` | 现脚本 `rounds_ok / requests_total` |
| **网络层拒绝率** | 网络/HTTP 层失败 / 总请求数 | 连接失败、HTTP 4xx/5xx、超时、流中断（脚本 `err` 分类：`http ...`/`request:...`/`stream:...`） |
| **模型层错误率** | 模型层失败 / 总请求数 | usage 缺失（`no-usage`）、空内容、模型报错等 |
| **错误样本** | 前 3 条 err 样例 | 现脚本已有 `err_samples` |

判定规则：`err` 字符串以 `http ` 或 `request:`（连接/超时）开头 → 网络层；以 `stream:`、`no-usage` 开头 → 模型层/流层。工具扩展需按此输出 `err_class` 字段（§6 R4）。

---

## 4. 与 v1 基准对照表

v1 体系（同参档位，来自 verification-logs / QA 报告）：

| 对照项 | v1 基线（2026-08-16 08:20–08:53） | BenchV2 对应档 | 可比性说明 |
|---|---|---|---|
| 32K c1 PR | 2424.15 / 2425.93（FULL32K A/B） | PR_C1_L32768（32768） | 同 ctx/conc/engine/rounds/temp，可直比 |
| 32K c1 DE | 98.06 / 99.07（coding，max_tokens 512） | DE_C1_coding（max_tokens 4096） | **输出长度不同** → 不作直接数值对比；DE 口径变化单独标注 |
| 131K c1 PR | 2182.11 / 2217.81（FULL131K A/B） | PR_C1_L131076（131076） | 前缀 131072 vs 131076 差 4 tokens，可直比 |
| 131K c1 DE | 92.21 / 96.72（coding，max_tokens 512） | DE 系列不设 131K 输入（用户要求 512） | 无对应；131K DE 已由 v1 FOLLOWUP 覆盖 |
| c4 agg DE（32K coding） | 193.55（+96.4% vs c1） | DE_C4_coding（agg） | **ctx 不同**（32K vs 512）→ 不直比数值，只比并发放大趋势 |
| c4 agg PR（32K） | 2782.72 | PR_C4_L32768（agg） | 同 32K 档位可直比 |

**对照规则**：以 PR_C1_L32768 与 PR_C1_L131076 作为与 v1 的锚定档（同参可比）；DE 系列因用户新规定输出 4096，作为新口径基线（v2 起生效），v1 DE 仅参考趋势。

---

## 5. 隔离与时间对齐机制

### 5.1 隔离原则

- **并发档之间串行**：C1 → C2 → C4 → C6，一次只测一个并发档，无并发叠加。
- **任务类型之间串行**：DE 的 coding/json/prose 各自独立组合串行执行；PR 各前缀长度独立组合串行执行。
- **输出类型独立会话/上下文**：每个组合独立发起请求（无共享 session/上下文延续）；随机 uuid 前缀防 prefix-cache，保证每请求独立 prefill。
- **档间冷却**：上一档结束后等待 `vllm:num_requests_running` 回落 0 且稳定 ≥30s 再起下一档。

### 5.2 monitor 纯净窗口判据

| 并发档 | monitor 判据 | 波间边界容忍 |
|---|---|---|
| C1 | running==1 | 起始 1 个 running=0 可接受（v1 已认可） |
| C2 | running==2 | 波间 running 波动（1-2）记录不判失败 |
| C4 | running==4 | 同 v1：1/32 采样 running=1 波间边界可接受 |
| C6 | running==6 | ⚠️ 引擎 `--max-num-seqs 6`，C6 在容量上限，波间边界/调度分批波动需记录；**若主体未达 6 则按「调度未跑满」判读（同 v1 C8 处置）** |

monitor 采样：每 5s 拉取 `vllm:num_requests_running`（与 v1 完全一致），写入 `monitor_<档>.log`；脚本内解析 running 到达/回落时间戳作为档窗口起止。

### 5.3 时间对齐

- 全部档位在同一环境状态批次内完成（同一引擎实例、同生产负载基线、无重启无配置变更）。
- 每档记录：`start_ts` / `end_ts`（ISO8601 + epoch），`elapsed_s`，以及该档 monitor running 轨迹摘要（min/max/均值、达到 C 的时长）。
- 总执行窗口：一次 bench 会话内连续完成 32 档；若中途引擎重建/重启，立即中止并标注（不可跨实例拼接）。

---

## 6. 工具能力差距清单（交 Rex 开发）

现有 `bench_prefill_decode_async.py`（`--group/--ctx/--concurrency/--tasks/--rounds/--engine/--out`）**不满足** v2 需求，需扩展（建议新 runner，生产脚本不动）：

| # | 需求 | 现状 | 扩展要求 |
|---|---|---|---|
| R1 | **输出长度控制**（DE 4096 / PR 1） | `TASK_MAX_TOKENS` 硬编码 coding=512/json=512/prose=256，无 CLI | 新增 `--max-tokens <int>` 覆盖；DE 档传 4096，PR 档传 1 |
| R2 | **输入长度/前缀长度控制** | `--ctx` 已支持 | 复用 `--ctx`；PR 档 512/2048/8192/32768/131076 逐个传入 |
| R3 | **ignore_eos 满长生成（DE 用）** | 无 | 新增 `--ignore-eos`；DE 档置 true 强制满长 4096（v1 FOLLOWUP 已验证服务端支持，避免 EOS 提前截断导致 decode 窗口不足）。若产品口径要保留真实 EOS 行为，则 DE 默认不开、单独加跑 ignore_eos 对照档 |
| R4 | **接受率分层统计** | `err` 字符串未分类 | 输出 `err_class`：`network`（http/connect/timeout）vs `model`（stream/no-usage）；summary 增加 `ok_rate / network_reject_rate / model_error_rate` |
| R5 | **dspark 计数器采样** | 无 | 每档前后采样 `/metrics` 的 `vllm:spec_decode_*` counter 差值 → summary 增加 `dspark_accept_rate / draft_per_request / per_pos_accept[]`（§3.3） |
| R6 | **monitor 集成** | v1 用外部 shell 循环采样 | runner 内嵌 5s 采样 `num_requests_running`，档窗口判据（§5.2）+ 冷却等待（§5.1）自动化 |
| R7 | **时间戳与清单** | summary 仅 elapsed_s | 每档记录 start/end ISO8601+epoch；批次 manifest.json 记录全部档位时间戳、总耗时、环境快照（四机 healthy、GPU、NCCL env、model list） |
| R8 | **PR 纯随机前缀模板（可选）** | 随机 uuid 填充 + 任务模板 | 新增 `--task plain`：仅随机 uuid 前缀无任务模板，PR 前缀长度口径更干净（fallback：用 coding 并标注） |
| R9 | **统一目录落盘** | 手动建目录 | runner 自动建 `verification-logs/BENCHV2_<YYYYMMDD_HHMMSS>/<档名>/`，写 rows+summary+monitor+bench+precheck |

**验收标准**：一次命令跑完矩阵，输出全部 32 档目录 + manifest.json；每档 summary 含 §3 全部指标；monitor.log 可复现 §5.2 判据；不修改生产脚本/配置。

---

## 7. 执行计划

### 7.1 档位顺序（按并发档分组）

```
[precheck] 四机 healthy / GPU 0%（含确认 2hop-s1 bench 已停）/ running==0 / /v1/models OK / dspark counter 归零确认
[calib]    tokens/unit 校准（每批次 1 次）
┌─ C1 ─────────────────────────────────────────────
│  DE_C1_coding → DE_C1_json → DE_C1_prose         (512 in / 4096 out)
│  PR_C1_L512 → L2048 → L8192 → L32768 → L131076   (max_tokens=1)
│  [冷却] running 回落 0 且稳定 30s
├─ C2 ─────────────────────────────────────────────
│  DE_C2_* ×3 → PR_C2_* ×5  → [冷却]
├─ C4 ─────────────────────────────────────────────
│  DE_C4_* ×3 → PR_C4_* ×5  → [冷却]
└─ C6 ─────────────────────────────────────────────
   DE_C6_* ×3 → PR_C6_* ×5  → [冷却]
[postcheck] GPU 回落 0 / running==0 / manifest 汇总
```

### 7.2 预计时长（基准：512 输入 DE 每请求 ~30-60s，131K PR c1 TTFT ~52s）

| 段 | 组合数 | 预估时长 | 说明 |
|---|---|---|---|
| 校准 + precheck | — | 5–8 min | 校准 1 次 + 四机检查 |
| C1 段 | 3 DE + 5 PR | 15–20 min | DE 单请求串行；131K PR 单请求 ~55s×3 |
| C2 段 | 3 DE + 5 PR | 15–20 min | 2 路并发，总时长略增 |
| C4 段 | 3 DE + 5 PR | 20–25 min | 4 路并发，agg 判读 |
| C6 段 | 3 DE + 5 PR | 25–35 min | ⚠️ 131K PR 6 路 prefill 大消息 allreduce 争用，可能显著拉长；C6 引擎容量上限，TTFT 分布宽 |
| 冷却 + 落盘 + postcheck | — | 10–15 min | 档间 30s 冷却 × 4 + 目录整理 |
| **合计** | **32 组合** | **≈ 105–135 min** | 建议预留 2.5h 窗口 |

### 7.3 窗口安排建议

- 单次连续执行（不跨实例），建议工作日生产空闲窗口 13:00–16:00。
- 若 131K PR 在 C6 超时（单请求 >600s），runner 记录并继续下一档（不中断整批）；summary 标注该档「超时/调度未跑满」。
- 若中途引擎重启：中止并标注，不拼接。

---

## 8. 风险与注意事项

1. **C6 = 引擎容量上限**（max-num-seqs 6）：C6 可能因调度分批出现 running 未满 6，判读为「指示性/上限」（沿用 v1 C8 处置）。
2. **DE 输出 4096 与 v1 不直比**：v1 DE 用 max_tokens 512；本方案 DE 为新口径，v1 只作趋势参考。
3. **131K PR 长 prefill**：单请求 TTFT ~52s，C6 下 6×131K 大消息 allreduce 可能显著变慢，预留超时余量。
4. **dspark 计数器污染**：若档间冷却不充分，全局 counter 差值会混入上一档残留 → 依赖 §5.2 冷却 + 纯净窗口；precheck 记录计数器起始值。
5. **2hop-s1 bench 仍在运行（阻断项）**：rank0（<node1>）python 4020321 自 11:07 起 99.3% CPU + 469MiB GPU，<node1> GPU util 92%，疑似卡死/长跑。**BenchV2 执行前必须由 2hop 测试方/SRE 停止该 bench**（`docker stop 2hop-s1-rank*` 或 kill 对应进程），否则 rank0 prefill/decode 吞吐被 CPU 抢占污染。QA 不擅自杀进程（生产只读纪律），先上报 team-lead 协调。
6. **生产只读**：不触碰任何配置；runner 只发 /v1 请求 + 读 /metrics。
7. **工具未就绪**：Rex 未交付 runner 前不执行；可用既有脚本按 R1/R2 最小 wrapper 先行验证（若需，QA 可做临时 wrapper 冒烟，但正式矩阵等 runner）。

---

## 9. 交付物清单

1. 本方案（本文档）。
2. 工具扩展需求（§6）→ 交 Rex。
3. 执行后：`verification-logs/BENCHV2_*/` 32 档数据 + manifest.json + QA 判读报告（对照 v1 锚定档、dspark 接受率、并发放大趋势）。

> 本方案由工程保障团队 QA 成员编制，关键决策请由人类工程负责人复核后批准执行。
