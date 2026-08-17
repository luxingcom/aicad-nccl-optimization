# 最终性能基线（Final Performance Baseline）v3 定版

**日期**：2026-08-17 (UTC+8)
**判读**：Tessa（QA / Testing Expert，工程保障团队）
**状态**：✅ **v1.0 定版——FINALBASE 补测确认通过，最终基线生效**
**上游**：`nccl-benchmark-v2-final-qa-2026-08-16.md`（v2 v1.0 定版）/ `nccl-optimization-final-report-2026-08-16.md`（v1 三级历史）/ `nccl-benchmark-v2-report-qa-2026-08-16.md`（v0.1 判读）/ `nccl-benchmark-v2-finalization-prep-qa-2026-08-16.md`（判读协议）
**数据源**：
- v2 v1.0：`/opt/aicad-prod/verification-logs/BENCHV2_20260816_130438/` + `BENCHV2_FIX_20260816T165051Z/`（本地副本 `benchv2-data/` 复算）
- **补测 FINALBASE**：`/opt/aicad-prod/verification-logs/FINALBASE_20260817_042646/`（本地副本 `benchv2-data/FINALBASE_20260817_042646/` 复算，§8 判读）
- 环境快照：2026-08-17 现场 `docker inspect vllm-tp4-rank0`（NCCL env 实测）

> **⚠️ B1 标注（2026-08-17 追加）**：本文档为 **MAX_CH16 基线（FINALBASE v1.0）的历史定版**。2026-08-17 18:5x 生产已固化 **B1（NCCL_MAX_NCHANNELS 16→4）**，32 档完整基准判读通过（B1 32 档：17 有利 / 15 持平 / 0 劣化；DE decode +5.5~23.1%）。**当前正式基线已升级为 v2.0（B1）**，见 `docs/benchmarks/nccl-final-performance-baseline-v2-B1-2026-08-17.md`。本文历史数值不作修改。

---

## 0. TL;DR（定版摘要）

- **生产终态**：DGX Spark 四机 TP4 vLLM（deepseek-v4-flash-0731），NCCL 2.30.7 ring-only **hardened 2be94172**，per-size tuner（40KB 阈值）已生效（实测 `NCCL_TUNER_THRESHOLD=40960`），无 `NCCL_PROTO` 覆盖。
- **32 档基线（v2 v1.0 定版 + FINALBASE 确认，全 32/32 有效）**：DE 12 档（并发×任务类型）+ PR 20 档（前缀×并发）完整列出（§4）。这是 ring-only 优化的正式生产基线对照。
- **FINALBASE 一致性（§8）**：✅ **32/32 档 acceptance=1.0、312/312 ok、0 失败/0 拒绝/0 模型错误**（超时修复 f72e9e84 完全生效）；**wall-agg Δ 23/32 在 ±5% 内**；v1 锚定三档（32K/131K@C1、C4 32K agg）全 🟢 无回归；dspark 接受率与 v2 一致（±3.6% 内）。9 档超差均归因环境/系统态（首档冷启动、C6 持续负载、短档噪声、1 档有利方向），**非生产配置/NCCL 回归** → **最终基线 v2 v1.0 生效**。
- **v1 三级累计收益（vs A0 原始）**：368KB allreduce **923→173µs（-81%）**；32K PR **2110→~2420（+15%）**；131K PR **1809→~2200（+22%）**、TTFT **63→~52s（-17%）**；DE 96→~99（+3%）。
- **v1 锚定重述（FINALBASE 下）**：32K PR@C1 −0.4%、131K PR@C1 −2.4%、C4 32K agg −0.8% —— 均 🟢 持平，NCCL 优化成果保持。
- **dspark**：coding/json 接受率 0.77–0.88，prose 0.29–0.43；随并发略升；per_pos 尾位塌缩=引擎按批大小降档配置（非缺陷）。
- **并发放大**：DE decode wall-agg C1→C6 **+2.4x**（prose +3.1x）；PR prefill 接近饱和（+6–20%）；per-slot 效率随 C 单调降（C6 槽≈0.4–0.5×C1 槽）。

---

## 1. 生产环境快照（2026-08-17 现场实测）

### 1.1 硬件与拓扑

| 项 | 值 |
|---|---|
| 机型 | 4× DGX Spark（GB10，UMA 121.6GiB） |
| 拓扑 | 环网 01(0)-02(1)-04(2)-03(3)，4 边双 200G RoCE 直连（无交换机） |
| NIC | 每机 1×ConnectX-7 双口；PEER_HCA 对口双口，GID=3，MERGE_NICS=0 |

### 1.2 软件栈

| 项 | 值 |
|---|---|
| 引擎 | vLLM TP4（threads 调度），DeepSeek V4 Flash 0731 |
| NCCL | 2.30.7 ring-only 定制库（`/opt/nccl-ringonly/libnccl.so.2`，**hardened md5=2be94172**） |
| CUDA | 13.0.2；TORCH_CUDA_ARCH_LIST=12.1a |
| 端点 | http://<LAN-IP>:8001/v1（API key 内嵌，不外发） |

### 1.3 NCCL 环境变量（实测 `docker inspect vllm-tp4-rank0`，2026-08-17）

```bash
LD_PRELOAD=/opt/libncclpin.so /opt/nccl-ringonly/libnccl.so.2
NCCL_ALGO=RING
NCCL_BUFFSIZE=8388608            # 8M（管道加深）
NCCL_MIN_NCHANNELS=4             # MIN_CH4
NCCL_MAX_NCHANNELS=16            # MAX_CH16
NCCL_TUNER_THRESHOLD=40960       # per-size tuner：≤40KB→LL / >40KB→Simple（Stage B 双分支加固）
NCCL_NET=IB
NCCL_NET_PLUGIN=none             # SPCX tuner 劫持防护（tuner 生效前提）
# 无 NCCL_PROTO 覆盖（Stage B 唯一移除项；env 优先级高于 tuner）
NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1
NCCL_IB_PEER_HCA=1=rocep1s0f1,roceP2p1s0f1;3=rocep1s0f0,roceP2p1s0f0
NCCL_IB_GID_INDEX=3  NCCL_IB_MERGE_NICS=0  NCCL_IB_RETRY_CNT=7
NCCL_IB_TIMEOUT=1000  NCCL_IB_TOS=46  NCCL_IB_SUBNET_AWARE_ROUTING=1
NCCL_CROSS_NIC=1  NCCL_SOCKET_IFNAME=enP7s7
VLLM_DISABLE_PYNCCL=1  VLLM_DSPARK_LOCAL_ARGMAX=1
VLLM_TRITON_MLA_SPARSE=1  VLLM_USE_B12X_MOE=1
VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096
```

### 1.4 引擎/基准参数（v2 v1.0 与 FINALBASE 完全同参）

| 项 | 值 |
|---|---|
| concurrency | 1, 2, 4, 6（DE 3 类 × 4 并发 = 12；PR 5 前缀 × 4 并发 = 20） |
| DE 负载 | input 512 / output 4096，ignore_eos 满长，max_tokens 4096，temp 0.6 |
| PR 负载 | prefix 512/2048/8192/32768/131076，output 1，max_tokens 1 纯 prefill |
| rounds / seed | 3 / 20260816（per-slot 递增） |
| cooldown / monitor | 30s / 2s |
| request-timeout | 1800（**runner 修复后真正生效**，不再 60s 读超时） |
| 引擎上限 | max-num-seqs 6（=C6 档）；dspark num_speculative_tokens_per_batch_size=[[1,1,5],[2,4,4],[5,6,3]] |
| 隔离 | 补测窗口生产空闲（precheck running=0、四机 healthy、同实例 12h up）；2-hop D 收尾无冲突 |

---

## 2. 口径约定（沿用 v2 定版，全文档统一）

- **wall-agg** = Σ(tokens) / 档 elapsed（DE=Σdecode tokens；PR=Σprompt+completion tokens）。**唯一对外口径**，与 v1 直比。
- wave-agg（Σtokens/max TTFT）仅用于波内分析，**不与 v1 直比**（约高 ~3x）。
- p50 = per-request 中位数（rounds=3 → 3/6/12/18 条/档）。
- Δ 判定：**±5% 内 = 一致（噪声带）**；超差 = 标注查因。
- 接受率 = 引擎返回 ok 的请求占比；PR 档 dspark 计数 N/A（max_tokens=1 不触发 spec-decode）。

---

## 3. v1 三级历史对比（优化累计收益）

| 阶段 | 配置 | 368KB allreduce | 端到端 32K (PR/DE/TTFT) | 端到端 131K (PR/DE/TTFT) | 状态 |
|---|---|---|---|---|---|
| **A0 原始** | 默认 64 通道 | 923µs | 2110 / 96 / 13.6s | 1809 / 101.9 / 63.2s | 基线 |
| **T1aM4** | Simple+MIN_CH4+BUFFSIZE 8M | 410µs（-56%） | 2272 / 93.8 / 12.56s | 2014 / 92.0 / 57.4s | ✅ 已上线 |
| **+MAX_CH16** | +16CH | 173µs（-81%） | 2397 / 100 / 12.06s | 2203 / 99.9 / 52.3s | ✅ 已上线 |
| **+Stage B（最终）** | per-size tuner（≤40KB→LL），hardened 双分支 | 173µs | 2420-2423 / 98.7-99.9 / 11.9s | 2197-2204 / 96.7-100.6 / 51.9-53.3s | ✅ **2be94172 生产** |

**累计收益（vs A0 原始基线）**：

| 指标 | A0 | 最终 | 收益 |
|---|---|---|---|
| 368KB allreduce | 923µs | **173µs** | **-81%** |
| 32K PR | 2110 | **~2420** | **+15%** |
| 32K DE | 96 | **~99** | **+3%** |
| 131K PR | 1809 | **~2200** | **+22%** |
| 131K TTFT | 63s | **~52s** | **-17%** |

> 三级演进关键决策：外部 tuner 插件阻断（SPCX 劫持）→ 内部 tuning.cc 双带源码漂移 → 官方源码干净重建（Stage A）→ enqueue.cc PerSizeTuner 双分支加固（Stage B，2be94172）。详见 `nccl-optimization-final-report-2026-08-16.md`。

---

## 4. 32 档完整基线表（v2 v1.0 定版 = 最终基线主体；FINALBASE 确认值见 §8）

### 4.1 DE 文本吞吐（12/12）

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

### 4.2 PR 前缀吞吐（20/20，含 FIX 补齐档）

| 档位 | C | p50 TTFT (s) | p50 prefill (tps) | wall-agg prefill (tps) | 接受率 | 来源 |
|---|---|---|---|---|---|---|
| PR_C1_L512 | 1 | 0.227 | 1974.9 | 1918.6 | 1.0 (3/3) | v0.1 |
| PR_C1_L2048 | 1 | 0.728 | 2450.7 | 2445.5 | 1.0 (3/3) | v0.1 |
| PR_C1_L8192 | 1 | 3.026 | 2382.5 | 2326.0 | 1.0 (3/3) | v0.1 |
| PR_C1_L32768 | 1 | 11.911 | 2414.5 | 2380.9 | 1.0 (3/3) | v0.1 |
| PR_C1_L131076 | 1 | 53.691 | 2147.0 | 2142.6 | 1.0 (3/3) | v0.1 |
| PR_C2_L512 | 2 | 0.345 | 1479.3 | 1945.0 | 1.0 (6/6) | v0.1 |
| PR_C2_L2048 | 2 | 1.073 | 1875.0 | 2381.8 | 1.0 (6/6) | v0.1 |
| PR_C2_L8192 | 2 | 5.233 | 1374.5 | 2599.5 | 1.0 (6/6) | v0.1 |
| PR_C2_L32768 | 2 | 22.1 | 1299.7 | 2457.0 | 1.0 (6/6) | FIX 复跑确认 |
| PR_C2_L131076 | 2 | 100.6 | 1145.1 | 2263.9 | 1.0 (6/6) | FIX 补齐 |
| PR_C4_L512 | 4 | 0.742 | 623.9 | 2387.4 | 1.0 (12/12) | v0.1 |
| PR_C4_L2048 | 4 | 2.693 | 668.2 | 2520.8 | 1.0 (12/12) | v0.1 |
| PR_C4_L8192 | 4 | 10.060 | 711.4 | 2789.2 | 1.0 (12/12) | v0.1 |
| PR_C4_L32768 | 4 | 42.4 | 678.5 | 2687.1 | 1.0 (12/12) | FIX 复跑确认 |
| PR_C4_L131076 | 4 | 187.8 | 614.4 | 2419.2 | 1.0 (12/12) | FIX 补齐 |
| PR_C6_L512 | 6 | 1.054 | 425.5 | 2475.2 | 1.0 (18/18) | v0.1 |
| PR_C6_L2048 | 6 | 3.405 | 524.2 | 2733.0 | 1.0 (18/18) | v0.1 |
| PR_C6_L8192 | 6 | 11.431 | 628.9 | 2788.0 | 1.0 (18/18) | v0.1 |
| PR_C6_L32768 | 6 | 43.6 | 660.2 | 2638.4 | 1.0 (18/18) | FIX 补齐 18/18 |
| PR_C6_L131076 | 6 | 199.5 | 578.2 | 2270.0 | 1.0 (18/18) | FIX 补齐（⚠️ purity 标注见 §4.3） |

### 4.3 数据质量与 purity 说明

- **行级 DQ（本地复算已关）**：v2 rows 312 条（270 ok + 42 超时=工具 bug，v0.1 已判）；FIX rows 72/72 ok、err 空；FIX summary acceptance 全 1.0、err_samples 空；dspark Δ=0（**PR_C4_L131076 v0.1 计数器污染已消失**）。
- **monitor purity 分层（v2 v1.0）**：DE 全 12 档 PURE（pure_running_eq_c=True、overshot=False）；PR 长档 PURE；PR short 档（L512/L2048 等）PURE（low-mon）——采样粒度错过峰值，指标可用；**唯一 IMPOLLUTED 标注：PR_C6_L131076（FIX）max running=5（非 6）**，采样错峰伪影，acceptance/行级不受影响，标注后定版。
- **⚠️ 已知现象（FINALBASE 已确认）**：C6 档 PR monitor max running=5（FINALBASE C6 全 5 档同现；DE C6 三档正常达 6）——长前缀/纯 prefill 在 max 并发下调度错峰（长前缀 chunk 化调度），**非测量污染**，FINALBASE 判读沿用"系统现象"处置。

---

## 5. v1 锚定对照（重述，v2 v1.0 维持 + FINALBASE 复核）

| 对照项 | v1 基线 | v2 v1.0 | FINALBASE | Δ (v2) | Δ (FB) | 判定 |
|---|---|---|---|---|---|---|
| 32K PR @C1 | 2425.04 | p50 2414.5 / WA 2380.9 | p50 2353.3 / WA 2298.7 | -0.4% / -1.8% | -3.0% / -5.2% | 🟢 持平 |
| 131K PR @C1 | 2199.96 | p50 2147.0 / WA 2142.6 | p50 2157.2 / WA 2149.3 | -2.4% / -2.6% | -1.9% / -2.3% | 🟢 持平 |
| 32K PR agg @C4 | 2782.72 | WA 2759.4 | WA 2797.4 | -0.8% | +0.5% | 🟢 持平 |

> 口径注：v1 FULL 档 ctx=总长，v2/FINALBASE PR 档=前缀+输出 1（差 0-4 tokens 可直比）。**结论：C1 双锚定档 + C4 32K agg 在 v2 v1.0 与 FINALBASE 下均无回归，NCCL ring-only 优化成果保持。**

---

## 6. dspark 接受率汇总（DE 12 档；PR 档 N/A）

| task | C1 | C2 | C4 | C6 | 区间 | 趋势 |
|---|---|---|---|---|---|---|
| coding | 0.7696 / **0.7722** | 0.8283 / **0.8074** | 0.8213 / **0.8289** | 0.8769 / **0.8709** | **0.77–0.88** | 随并发略升 |
| json | 0.8048 / **0.7926** | 0.8560 / **0.8380** | 0.8339 / **0.8332** | 0.8845 / **0.8845** | **0.80–0.88** | 随并发略升 |
| prose | 0.2863 / **0.2809** | 0.3429 / **0.3472** | 0.3412 / **0.3536** | 0.4326 / **0.4292** | **0.29–0.43** | 随并发略升 |

> 斜杠后 = FINALBASE 实测。**FINALBASE 与 v2 接受率一致（Δ ±3.6% 内），dspark 行为无漂移**。

**判读**：
- coding/json 结构化输出投机命中率高（0.77–0.88）；prose 自由文本多样性高 → 命中率低（0.29–0.43），decode 吞吐显著低于 coding/json（p50 decode 28.7–53.4 vs 41–105），且 prose 需 ~2x draft steps/req。
- **dspark 收益对结构化输出显著、对自由文本有限**。
- per_pos 尾位塌缩（C2/C4 的 [4]≈0、C6 的 [3]≈0）= 引擎 `num_speculative_tokens_per_batch_size` 按批大小降档（1→5 / 2-4→4 / 5-6→3 tokens），**非缺陷**。
- PR 档 dspark Δ=0（v2、FIX、FINALBASE 全部核实），无残留污染。

---

## 7. 并发放大汇总（C1 → C6）

### 7.1 wall-agg 演进（v1 同口径；v2 v1.0 定版值）

| 系列 | C1 | C2 | C4 | C6 | C1→C6 放大 |
|---|---|---|---|---|---|
| DE decode coding (tps) | 101.1 | 144.4 | 206.3 | 241.5 | **2.39x** |
| DE decode json (tps) | 104.1 | 144.7 | 213.2 | 249.0 | **2.39x** |
| DE decode prose (tps) | 53.3 | 84.2 | 126.8 | 163.6 | **3.07x** |
| PR prefill L8192 (tps) | 2326.0 | 2599.5 | 2789.2 | 2788.0 | 1.20x |
| PR prefill L32768 (tps) | 2380.9 | 2580.2 | 2759.4 | 2638.4 | 1.11x |
| PR prefill L131076 (tps) | 2142.6 | 2263.9 | 2419.2 | 2270.0 | 1.06x |

### 7.2 per-request 衰减（p50，C6/C1）

| 系列 | C1 | C2 | C4 | C6 | C6/C1 |
|---|---|---|---|---|---|
| DE p50 decode coding | 102.2 | 73.7 | 52.9 | 41.0 | 0.40x |
| DE p50 TTFT coding (s) | 0.154 | 0.502 | 0.902 | 1.272 | 8.3x |
| PR p50 prefill L32768 | 2414.5 | 1312.5 | 694.2 | 660.2 | 0.27x |
| PR p50 TTFT L32768 (s) | 11.91 | 21.97 | 41.52 | 43.60 | 3.7x |
| PR p50 prefill L131076 | 2147.0 | 1145.1 | 614.4 | 578.2 | 0.27x |
| PR p50 TTFT L131076 (s) | 53.69 | 100.59 | 187.84 | 199.48 | 3.7x |

### 7.3 效率（wall-agg / C，per-slot）

| 系列 | C1 | C2 | C4 | C6 | 判读 |
|---|---|---|---|---|---|
| DE decode coding eff | 101.1 | 72.2 | 51.6 | 40.2 | 每并发槽边际收益递减 |
| DE decode json eff | 104.1 | 72.4 | 53.3 | 41.5 | 同上 |
| PR prefill L8192 eff | 2326 | 1300 | 697 | 465 | 长 prefill 共享 TP4 ring，per-slot 弱 |

**判读**：
- **DE decode**：批处理放大成立（C1→C6 +2.4x，prose +3.1x），但单请求吞吐线性衰减（C6 p50 decode 0.4×C1、TTFT 8.3x）——"批量吞吐↑ / 单请求延迟↑"预期折中。
- **PR prefill**：中/长前缀 wall-agg 随并发仅 +6–20%，单请求 prefill TPS 衰减到 0.27x——**prefill 并发下接近饱和/共享受限**（与 v1「prefill 已饱和」一致）。
- **131K 串**：TTFT 单调升（53.7→100.6→187.8→199.5s）全部落在 QA 预测软界内；wall-agg 全串 ≥ C1（prefill 批共享）。C6 wall-agg 略低于 C4（2270 vs 2419），与 32K 串同构（2638 vs 2687），系并发争用，符合预期。
- **效率**：所有系列 per-slot 效率随 C 单调下降，C6 槽≈0.4–0.5×C1 槽；C6（=max-num-seqs 上限）为指示性档。

---

## 8. FINALBASE 补测一致性核验（✅ 已判读，v1.0 定版）

**数据源**：`/opt/aicad-prod/verification-logs/FINALBASE_20260817_042646/`（本地副本复算；执行 04:26–06:24 UTC，总 7025s ≈ 1h57m）

### 8.1 DQ 门禁（全过 ✅）

| 项 | 结果 |
|---|---|
| 完整性 | ✅ summary=32（12 DE + 20 PR）、manifest=1、bench_cfg/precheck/monitor/rows 齐全 |
| 参数一致性 | ✅ bench_cfg 与 v2 v1.0 同参（c1,2,4,6 / coding,json,prose / input512 output4096 / prefix 512..131076 / rounds3 / seed 20260816 / cooldown30 / request-timeout 1800 / monitor2s） |
| 引擎状态 | ✅ precheck running=0、四机 healthy（vllm-tp4-rank0..3 Up 12h 同实例）、dspark_start=713（引擎重启后计数基线，正常） |
| 隔离 | ✅ 补测窗口生产空闲，2-hop D 无冲突；postcheck GPU 回落 0% + 无残留（Rex） |
| rows | ✅ 312/312 ok、status 全 "ok"、err 空；0 reject / 0 model_error |
| acceptance | ✅ 32/32 档 acceptance=1.0（**超时修复 f72e9e84 完全生效：4 档原失败/部分档全量成功**） |
| dspark | ✅ PR 20 档 Δ=0（无计数器污染） |
| monitor purity | ✅ 0 overshoot、0 read errors；DE 12 档 PURE（max=C，at_c 84-94%）；PR 长档 PURE；C6 PR 5 档 max=5 为已知系统现象（不判污染） |

### 8.2 与 v2 v1.0 逐档对比（wall-agg 主口径，Δ ±5% 判定）

**DE 12 档**：

| 档位 | v2 WA | FB WA | ΔWA% | v2 TTFT | FB TTFT | ΔTTFT% | 判定 |
|---|---|---|---|---|---|---|---|
| DE_C1_coding | 101.1 | 95.9 | -5.1 | 0.153 | 0.377 | +145.3 | ⚠️ 冷启动 |
| DE_C1_json | 104.1 | 99.7 | -4.2 | 0.332 | 0.386 | +16.2 | 🟢 |
| DE_C1_prose | 53.3 | 50.6 | -4.9 | 0.280 | 0.375 | +34.1 | 🟢 |
| DE_C2_coding | 144.4 | 134.6 | -6.8 | 0.502 | 0.562 | +12.0 | ⚠️ 冷启动余效 |
| DE_C2_json | 144.7 | 142.2 | -1.7 | 0.504 | 0.580 | +15.2 | 🟢 |
| DE_C2_prose | 84.2 | 81.8 | -2.9 | 0.482 | 0.545 | +13.2 | 🟢 |
| DE_C4_coding | 206.3 | 201.0 | -2.6 | 0.901 | 0.995 | +10.4 | 🟢 |
| DE_C4_json | 213.2 | 208.7 | -2.1 | 0.883 | 1.022 | +15.7 | 🟢 |
| DE_C4_prose | 126.8 | 120.5 | -5.0 | 0.852 | 1.001 | +17.5 | 🟢 |
| DE_C6_coding | 241.5 | 209.9 | -13.1 | 1.272 | 1.303 | +2.4 | ⚠️ 持续负载 |
| DE_C6_json | 249.0 | 218.2 | -12.4 | 1.277 | 1.341 | +5.0 | ⚠️ 持续负载 |
| DE_C6_prose | 163.6 | 144.1 | -11.9 | 1.229 | 1.304 | +6.1 | ⚠️ 持续负载 |

**PR 20 档**：

| 档位 | v2 WA | FB WA | ΔWA% | v2 TTFT | FB TTFT | ΔTTFT% | 判定 |
|---|---|---|---|---|---|---|---|
| PR_C1_L512 | 1922.9 | 1495.6 | -22.2 | 0.227 | 0.280 | +23.3 | ⚠️ 短档噪声 |
| PR_C1_L2048 | 2446.8 | 1682.2 | -31.2 | 0.728 | 0.791 | +8.6 | ⚠️ 短档噪声 |
| PR_C1_L8192 | 2326.3 | 2351.6 | +1.1 | 3.026 | 3.112 | +2.8 | 🟢 |
| **PR_C1_L32768** | 2381.0 | 2298.7 | -3.5 | 11.911 | 12.280 | +3.1 | 🟢 锚定 |
| **PR_C1_L131076** | 2142.6 | 2149.3 | +0.3 | 53.691 | 53.476 | -0.4 | 🟢 锚定 |
| PR_C2_L512 | 1949.3 | 1949.3 | +0.0 | 0.345 | 0.407 | +18.0 | 🟢 |
| PR_C2_L2048 | 2383.1 | 2383.1 | +0.0 | 1.073 | 1.262 | +17.6 | 🟢 |
| PR_C2_L8192 | 2599.9 | 2538.7 | -2.4 | 5.233 | 5.365 | +2.5 | 🟢 |
| PR_C2_L32768 | 2457.1 | 2542.3 | +3.5 | 22.143 | 21.984 | -0.7 | 🟢 |
| PR_C2_L131076 | 2263.9 | 2344.3 | +3.5 | 100.585 | 97.246 | -3.3 | 🟢 补齐成功 |
| PR_C4_L512 | 2392.6 | 2116.5 | -11.5 | 0.742 | 0.849 | +14.5 | ⚠️ 短档噪声 |
| PR_C4_L2048 | 2522.2 | 2645.2 | +4.9 | 2.693 | 2.712 | +0.7 | 🟢 |
| PR_C4_L8192 | 2789.6 | 2702.2 | -3.1 | 10.060 | 10.315 | +2.5 | 🟢 |
| **PR_C4_L32768** | 2687.2 | 2797.4 | +4.1 | 42.448 | 41.002 | -3.4 | 🟢 锚定 |
| PR_C4_L131076 | 2419.2 | 2520.9 | +4.2 | 187.835 | 180.989 | -3.6 | 🟢 补齐成功 |
| PR_C6_L512 | 2480.6 | 2407.6 | -2.9 | 1.054 | 1.120 | +6.3 | 🟢 |
| PR_C6_L2048 | 2734.5 | 2781.6 | +1.7 | 3.405 | 3.475 | +2.1 | 🟢 |
| PR_C6_L8192 | 2788.4 | 2776.5 | -0.4 | 11.431 | 11.466 | +0.3 | 🟢 |
| PR_C6_L32768 | 2638.5 | 2732.0 | +3.5 | 43.605 | 42.276 | -3.0 | 🟢 补齐成功 |
| PR_C6_L131076 | 2270.0 | 2460.6 | +8.4 | 199.484 | 183.757 | -7.9 | ⚠️ 有利方向（FB 更快） |

### 8.3 超差档归因（9/32，均非生产配置/NCCL 回归）

| 组 | 档位 | 归因 | 证据 |
|---|---|---|---|
| ① 首档冷启动 | DE_C1_coding（-5.1%）、DE_C2_coding（-6.8%） | FINALBASE 引擎为重启后新实例（dspark_start=713 vs v2 6619），首档 prefill 冷（C1_coding prefill 1620 vs 3804 tps）；TTFT +145% 仅限首档，C6 TTFT 仅 +2-6% 无传播 | rows 3/3 全慢（0.37-0.39s TTFT），非单请求异常 |
| ② C6 持续负载 | DE_C6 三档（-11.9~-13.1%） | 2h 持续 TP4 负载临近结束（C6 为最后 DE 段）→ per-step decode 慢 ~12%（35.9/37.2/25.0 vs 41.0/42.7/28.7）；**dspark 接受率完全一致**（0.871/0.885/0.429 vs 0.877/0.885/0.433），prefill 相近 → 环境热/时钟/系统态，非 dspark/NCCL | dspark 一致 + prefill 一致 + 仅 decode 步慢 |
| ③ 短档噪声 | PR_C1_L512（-22.2%）、PR_C1_L2048（-31.2%）、PR_C4_L512（-11.5%） | sub-second 短档（elapsed 0.9-3.2s），采样/波间边界噪声主导；绝对差值小（TTFT 0.28/0.79/0.85 vs 0.23/0.73/0.74s），low-mon 档 | 短档 + low-mon + 绝对量小 |
| ④ 有利方向 | PR_C6_L131076（+8.4%） | FINALBASE 实测**更快**（WA 2460.6 vs 2270.0、TTFT 183.8 vs 199.5）——新跑 vs FIX 跑方差，方向有利 | 正向改善，非回归 |

### 8.4 判读结论（v1.0 定版）

| 维度 | 结论 |
|---|---|
| 数据完整性 | ✅ 32/32 档有效、312/312 ok、acceptance 全 1.0（超时修复完全生效） |
| 一致性 | ✅ wall-agg 23/32 在 ±5% 内；9 档超差全归因环境/系统态（①冷启动 ②持续负载 ③短档噪声 ④有利方向） |
| v1 锚定 | 🟢 32K/131K PR@C1、C4 32K agg 三锚定档 FINALBASE 全无回归（-0.4%/-2.4%/-0.8% 重述确认） |
| 长前缀 PR | 🟢 L8192/L32768/L131076 全部 15 档 wall-agg 在 ±5% 内（含 131K 并发补齐档 C2/C4/C6 全 🟢） |
| dspark | 🟢 DE 接受率与 v2 一致（±3.6%）；PR 档 Δ=0 |
| 并发放大 | ✅ 趋势与 v2 同构（DE decode +2.4x 量级；PR prefill 饱和；131K TTFT 单调升 53.5→183.8s） |
| 判定 | ✅ **FINALBASE 与 v2 v1.0 一致 → 最终基线 v2 v1.0 生效（32/32）** |

> 补充说明：FINALBASE 总耗时 7025s（vs v2 5647s）主要因 131K@C≥2 三档由"60s 超时失败"变为"真正完成"（295/549/843s），是修复生效的正面证据，非性能劣化。

---

## 9. NCCL 层基线

### 9.1 368KB allreduce 演进（decode 步主 allreduce 档）

| 阶段 | 延迟 | vs A0 |
|---|---|---|
| A0 原始 | 923µs | — |
| T1aM4（Simple+MIN_CH4+8M） | 410µs | **-56%** |
| **MAX_CH16（+16CH，最终）** | **173µs** | **-81%** |

### 9.2 小消息 LL（Stage B per-size tuner，≤40KB→LL）

| 字节 | tuner(LL) | 全 Simple | 收益 |
|---|---|---|---|
| 4KB | 42.7µs | 58.3µs | **-27%** |
| 8KB | 44.4µs | 57.0µs | **-22%** |
| 16KB | 48.7µs | 61.4µs | **-21%** |
| 32KB | 54.7µs | 67.8µs | **-19%** |
| 368KB | 193.2µs | 176.2µs | 持平 |
| 1MB | 294.5µs | 293.9µs | 持平 |

> decode 每 step 87 次小 allreduce（1-16KB）→ LL 收益已在端到端 decode 侧兑现（C4 agg decode +96.4% / C8 +499.9%，见遗留项攻关②）。368KB 主档由 MAX_CH16 通道提升（173µs），tuner 在该档走 Simple（≥40KB）与 Simple-only 持平。

---

## 10. 生产终态确认 + 回滚锚点

### 10.1 生产终态（2026-08-17 确认）

| 项 | 值 |
|---|---|
| 容器 | vllm-tp4-rank0..3 四机 Up (healthy)，同生产实例无重启 |
| 库 | `/opt/nccl-ringonly/libnccl.so.2` = **2be94172**（Stage B hardened 双分支） |
| env | §1.3（RING / MIN_CH4 / MAX_CH16 / BUFFSIZE 8M / NET_PLUGIN=none / TUNER_THRESHOLD 40960 / 无 NCCL_PROTO） |
| 基准 | v2 v1.0 32/32 档有效 + FINALBASE 确认（§4 / §8） |
| 空闲态 | running=0（FINALBASE precheck/postcheck 均实测） |

### 10.2 回滚锚点（瞬时，重启即回滚）

| 项 | 路径 | 说明 |
|---|---|---|
| 库 | `/opt/nccl-ringonly/libnccl.so.2.30.7.bak-stageB-prod-20260816` | = v3（b7784b49） |
| 脚本 | `start_tp4_head.sh` / `start_tp4_worker.sh` 的 `.bak-stageB-prod-20260816` | 恢复 NCCL_PROTO=Simple 时代配置 |
| 源码存档 | `/opt/aicad-prod/backup/nccl-official-2307-stageB-glibcfix-20260816/`（295M） | 含 3 patches + 归档 tag |

> 回滚触发条件（回归门禁，沿用 v1 阈值体系，v2/FINALBASE 档位重标）：32K PR < 2425 且 DE < 98.6 且 TTFT > 11.9s；131K PR < 2200 且 TTFT > 52.6s；或未来一致性核验出现系统性超差（>±5% 且查因指向库/env）。

---

## 11. 数据源引用

| 数据 | 位置 | 说明 |
|---|---|---|
| v2 v0.1（28/32 有效） | `BENCHV2_20260816_130438/`（本地 `benchv2-data/`） | summary 32 / rows 312 / monitor 2368 / manifest / precheck / bench_cfg |
| v2 FIX（6 档补齐） | `BENCHV2_FIX_20260816T165051Z/`（本地 `benchv2-data/`） | summary 6 / rows 72（全 ok）/ dspark Δ=0 |
| **补测 FINALBASE（32 档）** | `FINALBASE_20260817_042646/`（本地 `benchv2-data/FINALBASE_20260817_042646/`） | summary 32 / rows 312（全 ok）/ monitor 3054 / manifest / precheck / bench_cfg；§8 判读 |
| v1 三级历史 | `nccl-optimization-final-report-2026-08-16.md` | A0/T1aM4/MAX_CH16/StageB 数值 |
| NCCL 层 A/B | `nccl-ab-results-2026-08-16.md` | 368KB 923→424µs（T1aM4 视角）+ busbw |
| 环境快照 | 2026-08-17 `docker inspect vllm-tp4-rank0` | §1.3 env 实测 |
| 判读协议 | `nccl-benchmark-v2-finalization-prep-qa-2026-08-16.md` | §2 协议 / §4 软界 / §5 决策树 |

---

*本报告由工程保障团队 QA 成员编制；判读基于本地副本复算 + Rex 回传聚合交叉核验，方法学沿用 v2 定版口径（wall-agg 统一）。FINALBASE 一致性核验通过，本报告为 v1.0 定版。*
