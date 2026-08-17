# v2 基准测试（BenchV2）判读 QA 报告

**日期**：2026-08-16 (UTC+8)
**判读**：Tessa（QA / Testing Expert，工程保障团队）
**数据源**：`/opt/aicad-prod/verification-logs/BENCHV2_20260816_130438/`（已落盘完整；本报告基于本地副本 `deliverables/engineering-assurance/benchv2-data/` 复算）
**被测对象**：DGX Spark 四机环网 TP4 vLLM（DeepSeek V4 Flash 0731），NCCL 2.30.7 ring-only，dspark 投机解码，max-num-seqs 6
**执行窗口**：2026-08-16 13:04:40 → 14:38:47 UTC（总 5647.2s ≈ 94 min）
**状态**：✅ 判读完成

---

## 0. TL;DR（判读摘要）

- **数据完整性**：32/32 档齐全（12 DE + 20 PR），312 条请求 rows（117 DE + 195 PR），monitor 2368 采样，manifest/precheck/bench_cfg 齐全，行数与 summary 计数完全一致 ✅
- **可用性**：**28/32 档有效**（acceptance=1.0 且 monitor 纯净）；**4 档不可用/部分可用**：
  - `PR_C2_L131076`（0/6）、`PR_C4_L131076`（0/12）、`PR_C6_L131076`（0/18）全失败
  - `PR_C6_L32768`（12/18）部分失败
- **超时根因（关键结论）**：42 条失败全部为 **bench_v2.py 客户端 60s 读超时**（`stream:ConnectionError:...Read timed out`），**非引擎拒绝/引擎超时**。`run_one` 把请求读超时硬编码为 `min(request_timeout, 60)` = 60s；长 prefill（TTFT > 60s）时 urllib3 在 socket 阻塞读上抛 `ReadTimeoutError`，早于 1800s wall-clock 截止触发。**这是测试工具 bug，不是被测引擎问题。**
- **v1 锚定**：C1 PR 32K / 131K 无回归（−0.4% / −2.4%），C4 32K wall-agg −0.8% —— **NCCL 优化成果保持** ✅
- **dspark**：DE coding/json 接受率 0.77–0.88（高质量），prose 0.29–0.43（任务多样性所致）；随并发略升；per_pos 尾位在 C≥2 塌缩系引擎 `num_speculative_tokens_per_batch_size` 按批大小降档（非缺陷）；PR 档 N/A（max_tokens=1 不触发 spec-decode 计数）
- **结论**：v2 基准**部分可用**。修复 runner 读超时后补跑 4 档即可获得完整 v2 基线；本轮 28 档数据可作 v2 基线 v0.1 使用。

---

## 1. 数据校验

### 1.1 完整性核对

| 项 | 期望 | 实测 | 判定 |
|---|---|---|---|
| summary 档数 | 32（12 DE + 20 PR） | 32（12 DE + 20 PR） | ✅ |
| rows 请求数 | 312（DE 117 + PR 195） | 312（含 42 失败） | ✅ |
| manifest | 1 | 1（n_tiers=32） | ✅ |
| precheck | 1 | 1（running=0、四机 healthy、dspark counter 起始值 6619/26738/16722） | ✅ |
| monitor.log | 32 档 × 采样 | 2368 行、tier 1–32 | ✅ |
| bench_cfg | 1 | 1（与最终命令一致：conc 1/2/4/6、DE 512→4096、PR 512→131076、rounds 3、cooldown 30、request-timeout 1800、monitor 2s） | ✅ |
| 环境状态 | 同一引擎实例 | 无重启、四机 healthy、production 结束后回落 idle | ✅ |

### 1.2 monitor purity 分层

| 分层 | 判定标准 | 档数 | 档位 |
|---|---|---|---|
| **PURE** | reached_full_concurrency=True ∧ overshot=False ∧ n_during_at_c 高 | 24 | DE 全 12；PR C1_L8192/L32768/L131076、C2_L8192/L32768、C4_L8192/L32768、C6_L32768（采样见 1.3） |
| **PURE（low-mon）** | acc=1.0 但档太短 monitor 未捕到峰值（sampling 2s 错过） | 7 | PR C1_L512/L2048、C2_L512/L2048、C4_L512/L2048、C6_L512/L2048/L8192（见下注） |
| **INCONCLUSIVE** | 失败/部分失败或 overshoot | 5 | PR_C2_L131076、PR_C4_L131076（overshoot=True）、PR_C6_L32768（partial）、PR_C6_L131076、（+ PR_C4_L131076 dspark 污染） |

> 注：short-PR 档（elapsed 0.7–11.8s）`reached_full_concurrency=False` 且 max running < C，是因请求总时长 < monitor 2s 采样间隔（或恰好落在波间边界），属采样粒度限制而非纯度问题；其 acceptance=1.0 且 per-request 指标完整，判为可用。

### 1.3 异常档标注

| 档位 | 异常 | 影响 | 处置 |
|---|---|---|---|
| PR_C2_L131076 | acc=0.0（0/6，全 Read timed out） | PR 131K@C2 无数据 | 工具修复后补跑 |
| PR_C4_L131076 | acc=0.0（0/12，全 Read timed out）+ **overshot=True（running max=6>4）** + dspark counter 有残差（Δ175 drafts/467 acc） | PR 131K@C4 无数据；dspark 值受前档残留污染，**不可用** | 工具修复后补跑；dspark 该档作废 |
| PR_C6_L32768 | acc=0.667（12/18；每波 4 成 2 败） | 32K@C6 聚合指标偏小（wall-agg 1910 被失败稀释） | 工具修复后补跑；成功 12 条 per-request 数据可用 |
| PR_C6_L131076 | acc=0.0（0/18，全 Read timed out） | PR 131K@C6 无数据 | 工具修复后补跑 |
| PR_C1_L512/L2048 等 short 档 | monitor 未达 C（采样错过） | 仅 purity 标注降级，指标可用 | 接受（同 v1 处置） |

---

## 2. 完整指标表（32 档）

### 2.1 DE 文本吞吐（输入 512 / 输出 4096，ignore_eos 满长；full_length_ratio 全 1.0）

| 档位 | C | p50 TTFT (s) | p50 prefill (tps) | p50 decode (tps) | wall-agg decode (tps) | 接受率 |
|---|---|---|---|---|---|---|
| DE_C1_coding | 1 | 0.154 | 3803.9 | 102.2 | 101.1 | 1.0 (3/3) |
| DE_C1_json | 1 | 0.332 | 1784.8 | 105.3 | 104.1 | 1.0 (3/3) |
| DE_C1_prose | 1 | 0.280 | 2026.0 | 53.4 | 53.3 | 1.0 (3/3) |
| DE_C2_coding | 2 | 0.502 | 1165.6 | 73.7 | 144.4 | 1.0 (6/6) |
| DE_C2_json | 2 | 0.504 | 1180.1 | 73.8 | 144.7 | 1.0 (6/6) |
| DE_C2_prose | 2 | 0.482 | 1169.0 | 42.7 | 84.2 | 1.0 (6/6) |
| DE_C4_coding | 4 | 0.902 | 660.6 | 52.9 | 206.3 | 1.0 (12/12) |
| DE_C4_json | 4 | 0.884 | 668.9 | 55.3 | 213.2 | 1.0 (12/12) |
| DE_C4_prose | 4 | 0.852 | 665.2 | 32.3 | 126.8 | 1.0 (12/12) |
| DE_C6_coding | 6 | 1.272 | 471.4 | 41.0 | 241.5 | 1.0 (18/18) |
| DE_C6_json | 6 | 1.277 | 468.0 | 42.7 | 249.0 | 1.0 (18/18) |
| DE_C6_prose | 6 | 1.229 | 461.2 | 28.7 | 163.6 | 1.0 (18/18) |

> wall-agg decode = Σ(completion_tokens) / 档 wall time（v1 同口径，见 §5）。

### 2.2 PR 前缀吞吐（max_tokens=1 纯 prefill）

| 档位 | C | p50 TTFT (s) | p50 prefill (tps) | wall-agg prefill (tps) | 接受率 |
|---|---|---|---|---|---|
| PR_C1_L512 | 1 | 0.227 | 1974.9 | 1918.6 | 1.0 (3/3) |
| PR_C1_L2048 | 1 | 0.728 | 2450.7 | 2445.5 | 1.0 (3/3) |
| PR_C1_L8192 | 1 | 3.026 | 2382.5 | 2326.0 | 1.0 (3/3) |
| PR_C1_L32768 | 1 | 11.911 | 2414.5 | 2380.9 | 1.0 (3/3) |
| PR_C1_L131076 | 1 | 53.691 | 2147.0 | 2142.6 | 1.0 (3/3) |
| PR_C2_L512 | 2 | 0.345 | 1479.3 | 1945.0 | 1.0 (6/6) |
| PR_C2_L2048 | 2 | 1.073 | 1875.0 | 2381.8 | 1.0 (6/6) |
| PR_C2_L8192 | 2 | 5.233 | 1374.5 | 2599.5 | 1.0 (6/6) |
| PR_C2_L32768 | 2 | 21.968 | 1312.5 | 2580.2 | 1.0 (6/6) |
| **PR_C2_L131076** | 2 | — | — | — | **0.0 (0/6)** ⚠️ |
| PR_C4_L512 | 4 | 0.742 | 623.9 | 2387.4 | 1.0 (12/12) |
| PR_C4_L2048 | 4 | 2.693 | 668.2 | 2520.8 | 1.0 (12/12) |
| PR_C4_L8192 | 4 | 10.060 | 711.4 | 2789.2 | 1.0 (12/12) |
| PR_C4_L32768 | 4 | 41.517 | 694.2 | 2759.4 | 1.0 (12/12) |
| **PR_C4_L131076** | 4 | — | — | — | **0.0 (0/12)** ⚠️ |
| PR_C6_L512 | 6 | 1.054 | 425.5 | 2475.2 | 1.0 (18/18) |
| PR_C6_L2048 | 6 | 3.405 | 524.2 | 2733.0 | 1.0 (18/18) |
| PR_C6_L8192 | 6 | 11.431 | 628.9 | 2788.0 | 1.0 (18/18) |
| **PR_C6_L32768** | 6 | 43.083 | 667.5 | 1910.2* | **0.667 (12/18)** ⚠️ |
| **PR_C6_L131076** | 6 | — | — | — | **0.0 (0/18)** ⚠️ |

\* wall-agg 被 6 条失败稀释，仅参考；成功 12 条 per-request TTFT 40.3–44.2s、prefill 652–713 tps 为有效数据。

---

## 3. v1 锚定对照（同参直比）

| 对照项 | v1 基线（来源：optimization-final-report / stageb-fulltest） | v2 对应档 | v2 值 | Δ | 判定 |
|---|---|---|---|---|---|
| 32K PR @C1 | 2424.15 / 2425.93（FULL32K A/B，合并 2425.04） | PR_C1_L32768 | p50 2414.5 / wall-agg 2380.9 | −0.4% / −1.8% | 🟢 持平 |
| 131K PR @C1 | 2182.11 / 2217.81（FULL131K A/B，合并 2199.96） | PR_C1_L131076 | p50 2147.0 / wall-agg 2142.6 | −2.4% / −2.6% | 🟢 持平 |
| 32K PR agg @C4 | 2782.72（v1 followup c4 agg prefill） | PR_C4_L32768 | wall-agg 2759.4 | −0.8% | 🟢 持平 |
| DE decode agg @C4 | 193.55（v1 followup c4 coding，max_tokens 512） | DE_C4_coding | wall-agg 206.3 | +6.6% | 🟢 持平/略升（口径见下） |

**口径差异说明**：
- v1 FULL32K/FULL131K 的 ctx 为**总长**（32768/131072），v2 PR 档为**前缀 32768/131076 + 输出 1**；prefill 主体一致（差 0–4 tokens），可直比。
- v2 agg 统一采用 **wall-time 口径**（Σtokens / 档 wall time）与 v1 agg 对齐；v2 的 wave-agg（Σtokens / max TTFT，见 §5 注）比 v1 口径约高 ~3x，**不可与 v1 直比**，仅用于 v2 内部波级分析。
- v1 DE 输出 max_tokens=512，v2 DE 输出 4096（新口径）→ DE 数值不作直接对比，仅趋势参考。
- 引擎参数一致（threads / temp 0.6 / rounds 3 / dspark on / prefix-cache 随机 uuid 防命中）。

**锚定结论**：**C1 双锚定档（32K/131K）与 C4 32K agg 均无回归**，NCCL ring-only 优化成果在 v2 基准下保持。131K@C1 TTFT 53.7s 略高于 v1（51.9/53.3s），Δ+0.8–3.4%，在噪声范围内。

---

## 4. dspark 接受率（DE 档；PR 档 N/A）

### 4.1 总接受率与位置分布（按并发趋势）

| task | C | 总接受率 | per_pos[0] | [1] | [2] | [3] | [4] | drafts/req | draft_tokens/req |
|---|---|---|---|---|---|---|---|---|---|
| coding | 1 | 0.7696 | 0.940 | 0.856 | 0.765 | 0.681 | 0.606 | 845 | 4225 |
| coding | 2 | 0.8283 | 0.947 | 0.873 | 0.790 | 0.704 | **0.005** | 948 | 3801 |
| coding | 4 | 0.8213 | 0.946 | 0.867 | 0.779 | 0.693 | **0.001** | 956 | 3825 |
| coding | 6 | 0.8769 | 0.951 | 0.880 | 0.801 | **0.005** | **0.000** | 1126 | 3387 |
| json | 1 | 0.8048 | 0.945 | 0.887 | 0.809 | 0.729 | 0.655 | 815 | 4077 |
| json | 2 | 0.8560 | 0.957 | 0.902 | 0.826 | 0.740 | **0.004** | 925 | 3706 |
| json | 4 | 0.8339 | 0.949 | 0.886 | 0.796 | 0.706 | **0.002** | 944 | 3781 |
| json | 6 | 0.8845 | 0.949 | 0.897 | 0.809 | **0.004** | **0.001** | 1119 | 3367 |
| prose | 1 | 0.2863 | 0.667 | 0.400 | 0.216 | 0.104 | 0.045 | 1685 | 8423 |
| prose | 2 | 0.3429 | 0.665 | 0.400 | 0.213 | 0.105 | **0.002** | 1717 | 6938 |
| prose | 4 | 0.3412 | 0.670 | 0.395 | 0.205 | 0.094 | **0.000** | 1732 | 6930 |
| prose | 6 | 0.4326 | 0.673 | 0.409 | 0.225 | **0.006** | **0.000** | 1772 | 5375 |

### 4.2 判读

- **PR 档 N/A**：全部 PR 档 dspark Δ≈0（max_tokens=1 不进入 spec-decode 计数路径）。唯一例外 `PR_C4_L131076` Δ=175 drafts/467 acc —— 为前档（C4_L32768）请求在客户端断连后引擎侧残留 decode 的**计数器污染**，该档 dspark 值作废。
- **任务类型分化**：coding/json 接受率 0.77–0.88（高），prose 0.29–0.43（低）。prose 输出 token 多样性高 → 投机命中率低 → decode 吞吐显著低于 coding/json（p50 decode 28.7–53.4 vs 41–105），且 prose 需要 ~2x 的 draft steps/req（1685–1772 vs 815–1126）。**dspark 收益对结构化输出（coding/json）显著，对自由文本（prose）有限。**
- **并发趋势**：总接受率随并发略升（coding 0.77→0.88；json 0.80→0.88；prose 0.29→0.43），draft_tokens/req 随并发下降（4225→3387）。
- **per_pos 尾位塌缩 = 引擎配置，非缺陷**：vLLM 启动参数 `num_speculative_tokens_per_batch_size=[[1,1,5],[2,4,4],[5,6,3]]` 规定 batch 1→5 tokens、batch 2-4→4、batch 5-6→3。因此 C1 时 per_pos[4] 正常（0.61–0.66），C2/C4 时 per_pos[4]≈0，C6 时 per_pos[3] 也≈0 —— 与批大小降档完全对应。draft_tokens/req 数值（C1=5.0/step、C2/C4≈4.0、C6≈3.0）进一步印证。
- **可用性**：DE 12 档 dspark 数据纯净可用（counter 差值在纯净窗口内采样）。

---

## 5. 并发放大趋势（C1 → C6）

### 5.1 wall-agg（v1 同口径）

| 系列 | C1 | C2 | C4 | C6 | C1→C6 放大 |
|---|---|---|---|---|---|
| DE decode coding (tps) | 101.1 | 144.4 | 206.3 | 241.5 | 2.39x |
| DE decode json (tps) | 104.1 | 144.7 | 213.2 | 249.0 | 2.39x |
| DE decode prose (tps) | 53.3 | 84.2 | 126.8 | 163.6 | 3.07x |
| PR prefill L8192 (tps) | 2326.0 | 2599.5 | 2789.2 | 2788.0 | 1.20x |
| PR prefill L32768 (tps) | 2380.9 | 2580.2 | 2759.4 | 1910.2* | 1.16x*（*C6 被失败稀释） |
| PR prefill L131076 (tps) | 2142.6 | — | — | — | 不可用（C≥2 失败） |

### 5.2 per-request 衰减（p50）

| 系列 | C1 | C2 | C4 | C6 | C6/C1 |
|---|---|---|---|---|---|
| DE p50 decode coding | 102.2 | 73.7 | 52.9 | 41.0 | 0.40x |
| DE p50 TTFT coding (s) | 0.154 | 0.502 | 0.902 | 1.272 | 8.3x |
| PR p50 prefill L32768 | 2414.5 | 1312.5 | 694.2 | 667.5 | 0.28x |
| PR p50 TTFT L32768 (s) | 11.91 | 21.97 | 41.52 | 43.08 | 3.6x |
| PR p50 prefill L131076 | 2147.0 | — | — | — | — |

### 5.3 效率（wall-agg / C）

| 系列 | C1 | C2 | C4 | C6 | 判读 |
|---|---|---|---|---|---|
| DE decode coding eff | 101.1 | 72.2 | 51.6 | 40.2 | 每并发槽边际收益递减（C2 槽≈0.7×C1、C6 槽≈0.4×C1） |
| DE decode json eff | 104.1 | 72.4 | 53.3 | 41.5 | 同上 |
| PR prefill L8192 eff | 2326 | 1300 | 697 | 465 | 长 prefill 下并发共享 TP4 ring，per-slot 收益弱 |

### 5.4 判读

- **DE decode**：并发批处理放大成立（C1→C6 wall-agg +2.4x，prose +3.1x），但单请求吞吐线性衰减（C6 时 p50 decode 仅 C1 的 0.4x，TTFT 8.3x）—— 符合「批量吞吐↑ / 单请求延迟↑」的预期折中，v1 已见同构趋势（c4 agg decode 193.55）。
- **PR prefill**：中前缀（L8192/L32768）wall-agg 随并发仅 +16–20%，且单请求 prefill TPS 严重衰减（L32768：2414→668，0.28x）。**prefill 在并发下接近饱和/共享受限**，与 v1「prefill 已饱和」结论一致。
- **131K 段**：并发放大无法测量（见 §6），修复后需补跑以补全该段曲线。
- **效率**：所有系列 per-slot 效率随 C 单调下降，C6 槽约 0.4–0.5x 于 C1 槽；C6（=max-num-seqs 上限）为指示性档。

> **口径注**：v2 summary 未输出 agg 字段，本报告 wall-agg 由 rows 复算（Σtokens/档 wall time）；另按方案 §3.2 的 wave-agg（Σtokens/max TTFT）复算得 C1 档 inflate ≈ 3x、C4 档 ≈ 3x 的波级值，仅用于波内批吞吐分析，不与 v1 直比。

---

## 6. 超时分析（重点）

### 6.1 失败清单与表象

| 档位 | 失败数 | 全部 err | elapsed | monitor 峰值 |
|---|---|---|---|---|
| PR_C2_L131076 | 6/6 | `stream:ConnectionError:HTTPConnectionPool(host='<LAN-IP>', port=8001): Read timed out.` | 181.4s | running=2（全程） |
| PR_C4_L131076 | 12/12 | 同上 | 183.0s | running max=6（overshoot） |
| PR_C6_L32768 | 6/18 | 同上 | 181.0s | running max=6（2/91 采样达 6） |
| PR_C6_L131076 | 18/18 | 同上 | 184.2s | running max=4 |

所有失败 `status=other`、无 TTFT/total（客户端未收到完整响应）。无 http_err / conn_err / model_err / timeout（按当前分类）。

### 6.2 根因（代码级定位）

`bench_v2.py::run_one`（第 152–153 行）：

```python
r = session.post(url, json=payload, headers=headers, stream=True,
                 timeout=(connect_timeout, min(timeout, 60)))   # ← 读超时硬编码 ≤60s
```

- `--request-timeout 1800` 本意是单请求总超时，但实现把 **urllib3 每读（inactivity）超时** 设为 `min(1800, 60)=60s`。
- 长 prefill（131K，C1 单请求 TTFT≈53.7s，C≥2 争用下 >60s）期间服务端 **不发送任何 SSE 字节** >60s → urllib3 socket 阻塞读抛 `ReadTimeoutError` → 在流式 `iter_lines` 中以 `ConnectionError` 形式泄漏（urllib3 异常未经 requests 包装为 `ReadTimeout`）→ 被第 211 行 `except Exception` 捕获，归类为 `other`。
- 第 176 行的 **1800s wall-clock 截止检查永远等不到**：阻塞读在 60s 无数据时就抛异常了。

### 6.3 证据链

1. **elapsed ≈ 3×60s**：四个失败档 elapsed 181.0–184.2s = 3 波 × ~60s（每波所有请求在 60s 读超时同时失败）→ 与 60s 读超时完全吻合（若是 1800s 超时，elapsed 应 >1800s 或包含成功）。
2. **成功档 TTFT 贴 60s 下界**：`PR_C1_L131076` 成功 TTFT 53.22–54.00s（恰在 60s 内，余量仅 ~6s）；`PR_C6_L32768` 成功 12 条 TTFT 40.3–44.2s，每波恰有 2 条 >60s 失败 —— 精确落在 60s 阈值两侧。
3. **引擎非拒绝/非超时**：monitor 显示失败窗口全程 running 维持预期 C（C2=2 全程、C4 曾达 6、C6=4），引擎在持续处理；无 4xx/5xx、无 finish_reason=error、无 max-num-seqs 拒绝特征（C2/C4 本可容纳）。
4. **统一错误串**：42 条失败错误串逐字节一致，均为客户端连接池读超时。

**排除项**：非引擎 request-timeout（引擎未设）、非 max-num-seqs=6 排队拒绝（C2 也失败）、非模型层错误、非网络不通（同窗口其他请求成功）。

### 6.4 建议（按优先级）

1. **【P0 修复 runner】读超时放开**：将 `min(timeout, 60)` 改为 `timeout`（即 1800s），或至少 > 最大预期 TTFT（长前缀档建议 ≥600s）。让 wall-clock 1800s 截止真正生效。建议长 prefill 档单独加大预算。
2. **【P0 修复分类】stream 层读超时归类**：`except Exception` 分支对含 `Read timed out`/`timed out` 的 `stream:ConnectionError` 归为 `timeout`（网络层），修正 acceptance 计数（现 42 条被计为 `other`）；方案 §3.4 的 `stream:`→模型层映射需细化（连接/超时属网络层，`no-usage`/空内容/`finish_reason=error` 属模型层）。
3. **【P1 补跑 4 档】**：修复后补跑 `PR_C2_L131076`、`PR_C4_L131076`、`PR_C6_L32768`、`PR_C6_L131076`，获得完整 131K 并发曲线。建议引擎侧同时记录请求完成日志以核对真实 TTFT。
4. **【P2 引擎参数观察】**：若修复后 131K@C≥2 TTFT 仍远超 60s（预期 60–300s），可评估 `--max-num-seqs`、`--long-prefill-token-threshold`（现 1024，长前缀 chunk 化调度）或调度策略对长前缀并发的排队影响；本轮数据不足以判定引擎侧是否需调参。
5. **【P2 基准口径】**：为长前缀并发档设置独立超时阈值（如 600s）而非全局 1800s，避免一档超时拖垮整批；或将 131K 段从主矩阵拆出单独执行。

---

## 7. 结论

### 7.1 v2 基准可用性评估

| 维度 | 结论 |
|---|---|
| 数据完整性 | ✅ 32/32 档落盘齐全、行级一致、monitor/precheck/manifest 完整 |
| 有效性 | ✅ **28/32 档有效**（DE 全 12 档 + PR 16 档）；❌ 4 档（131076@C2/C4/C6、32768@C6）因工具读超时不可用 |
| 根因归属 | 客户端 60s 读超时（测试工具 bug），**非引擎/网络/模型问题** |
| v1 一致性 | 🟢 C1 32K/131K PR 无回归（−0.4%/−2.4%）、C4 32K agg −0.8% |
| dspark | ✅ DE 档可用（coding/json 高接受率 0.77–0.88；prose 0.29–0.43）；PR 档 N/A |
| 并发放大 | ✅ DE decode +2.4x（C1→C6）符合预期；PR prefill 饱和（+16–20%）与 v1 一致 |

**总体判定**：v2 基准**部分可用**。作为回归对照：**通过**（v1 锚定档无回归 + DE 全档有效）。作为全矩阵基准：**待补跑 4 档后定版**。

### 7.2 后续优化对照基线建议

1. **v2 基线 v0.1（即刻生效）**：本轮 28 档有效数据 + 明确标注的 4 档缺口，可作当前 ring-only 优化状态的对照基线。
2. **v2 基线 v1.0（建议）**：修复 runner 读超时 + 分类后补跑 4 档，形成完整 32 档基线；同时将 wave-agg 口径明确写入 runner summary（建议 wall-time 口径为主、wave 口径为辅，避免跨版本歧义）。
3. **dspark 专项基线**：如需评估 dspark 质量，建议加跑固定 spec depth（如统一 5）对照档，与生产按批大小降档配置解耦；并补一组无投机（spec off）同参对照以量化 dspark 增益。
4. **回归门禁**：沿用 v1 阈值体系（32K PR 2425 / DE 98.6 / TTFT 11.9；131K PR 2200 / TTFT 52.6），在 v2 修复后以 v2 档位重标基线阈值。

---

## 附：数据文件索引

| 文件 | 说明 |
|---|---|
| `summary_v2.json` | 32 档聚合（含 monitor purity / dspark / acceptance / p50 全套） |
| `rows_v2.csv` | 312 条请求级（含 42 失败 err 全文） |
| `manifest_v2.json` | 32 tier 时间戳 + 环境快照 |
| `monitor_v2.log` | 2368 行 running 轨迹（tier 1–32） |
| `precheck_v2.json` | 四机 healthy / running=0 / dspark counter 起始值 |
| `bench_v2.json` | 执行参数（与最终命令一致） |

> 本报告由工程保障团队 QA 成员编制；数据判读基于本地副本复算，所有数值可在 rows_v2.csv / summary_v2.json 中复核。
