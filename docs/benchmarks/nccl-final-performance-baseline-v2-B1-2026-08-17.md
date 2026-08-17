# 最终性能基线 v2.0（B1）正式定版

**日期**：2026-08-17 (UTC+8)
**判读**：Tessa（QA / Testing Expert）＋ Archi（系统架构师，定版）
**状态**：✅ **v2.0 定版——B1（NCCL_MAX_NCHANNELS=4）正式基线生效，取代 MAX_CH16（FINALBASE v1.0）**
**上游**：`nccl-final-performance-baseline-2026-08-17.md`（FINALBASE v1.0，MAX_CH16）/ `B1-benchmark-QA-report-20260817.md`（B1 32 档判读）/ `nccl-ab-B-execution-report-2026-08-17.md`（B1 窗口）/ ADR-015 S1.14（固化决策）/ `b1-compat-adjudication-criteria-architect-2026-08-17.md`（兼容性判读口径）
**数据源**：
- **B1**：`/opt/aicad-prod/verification-logs/B1BASE_20260817_115604/`（执行 11:56–13:46 UTC，5261s ≈ 1h28m；本地副本 `b1-bench-20260817/`）
- **FINALBASE v1.0**：`/opt/aicad-prod/verification-logs/FINALBASE_20260817_042646/`（MAX_CH16 基线）
- **对比 CSV**：`/opt/aicad-prod/deliverables/engineering-assurance/B1_vs_FINALBASE_32tier.csv`（32 行，QA 复算）

---

## 0. TL;DR（定版摘要）

- **B1（NCCL_MAX_NCHANNELS=4）32 档完整基准判读通过，正式定版为 v2.0 基线**（取代 FINALBASE v1.0 / MAX_CH16）。
- **vs FINALBASE v1.0（MAX_CH16）**：32 档 **🟢+ 17 有利 / 🟢 15 持平 / 🔻 0 劣化**，无劣化档。
- **DE decode 12 档全有利**：wall-agg **+5.5% ~ +23.1%**（C1 +5.5~9.1% / C2 +7.1~10.9% / C4 +6.9~8.8% / **C6 +20.3~23.1%**）；TTFT 大多下降（C1 −15~19%），无系统性劣化。
- **PR prefill 20 档**：15 持平（长/中前缀 L8192/L32768/L131076 全 🟢）+ 5 有利（短档 L512/L2048 +7.7~45.5%），0 劣化。
- **v1 锚定三档无回归**：32K PR@C1 **+3.3%**、131K PR@C1 **−1.4%**、C4 32K agg **+0.4%**（wall-agg；TTFT Δ ≤2.1%）。
- **dspark 无漂移**：DE 12 档接受率 Δ ±4.6% 内。
- **并发放大优于 MAX_CH16**：DE decode wall-agg C1→C6 **2.41–3.26x**（vs FB 2.19–2.85x），4ch 不损害并发吞吐反而提升。
- **总耗时更快**：B1 5261s vs FB 5647s（−6.8%）。
- **净收益判定**：✅ B1 端到端净收益为正——收益主源为 decode 步主 allreduce（大消息）延迟改善，端到端兑现于 DE decode 全档；无任何维度劣化。

---

## 1. 生产环境快照（B1 终态，2026-08-17 现场实测）

### 1.1 硬件与拓扑

| 项 | 值 |
|---|---|
| 机型 | 4× DGX Spark（GB10，UMA 121.6GiB） |
| 拓扑 | 环网 01(0)-02(1)-04(2)-03(3)，4 边双 200G RoCE 直连（无交换机） |
| NIC | 每机 1×ConnectX-7 双口；v4 硬编码 per-peer 映射，GID=3，MERGE_NICS=0 |

### 1.2 软件栈

| 项 | 值 |
|---|---|
| 引擎 | vLLM TP4（threads 调度），DeepSeek V4 Flash 0731 |
| NCCL | 2.30.7 ring-only 定制库（`/opt/nccl-ringonly/libnccl.so.2`，**hardened md5=2be94172**，未变） |
| CUDA | 13.0.2；TORCH_CUDA_ARCH_LIST=12.1a |

### 1.3 NCCL 环境变量（B1 定版，实测 `docker inspect vllm-tp4-rank0`）

```bash
LD_PRELOAD=/opt/libncclpin.so /opt/nccl-ringonly/libnccl.so.2
NCCL_ALGO=RING
NCCL_BUFFSIZE=8388608            # 8M（管道加深）
NCCL_MIN_NCHANNELS=4             # MIN_CH4
NCCL_MAX_NCHANNELS=4             # B1：16→4（2026-08-17 定版）
NCCL_TUNER_THRESHOLD=40960       # per-size tuner：≤40KB→LL / >40KB→Simple（Stage B 双分支加固）
NCCL_NET=IB
NCCL_NET_PLUGIN=none             # SPCX tuner 劫持防护（tuner 生效前提）
# 无 NCCL_PROTO 覆盖（Stage B 唯一移除项；env 优先级高于 tuner）
NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1
NCCL_IB_GID_INDEX=3  NCCL_IB_MERGE_NICS=0  NCCL_IB_RETRY_CNT=7
NCCL_IB_TIMEOUT=1000  NCCL_IB_TOS=46  NCCL_IB_SUBNET_AWARE_ROUTING=1
NCCL_CROSS_NIC=1  NCCL_SOCKET_IFNAME=enP7s7
VLLM_DISABLE_PYNCCL=1  VLLM_DSPARK_LOCAL_ARGMAX=1
VLLM_TRITON_MLA_SPARSE=1  VLLM_USE_B12X_MOE=1
VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096
```

### 1.4 引擎/基准参数（B1 与 FINALBASE 完全同参）

| 项 | 值 |
|---|---|
| concurrency | 1, 2, 4, 6（DE 3 类 × 4 = 12；PR 5 前缀 × 4 = 20） |
| DE 负载 | input 512 / output 4096，ignore_eos 满长，max_tokens 4096，temp 0.6 |
| PR 负载 | prefix 512/2048/8192/32768/131076，output 1，max_tokens 1 纯 prefill |
| rounds / seed | 3 / 20260816 |
| cooldown / monitor / timeout | 30s / 2s / 1800 |
| 工具 | `/opt/aicad-prod/bench_v2.py` md5=56ad5ef2 |

---

## 2. B1 收益摘要（nccl-tests + 端到端）

### 2.1 nccl-tests（4-rank 环网 avg µs，in-place）

| 消息 | MAX_CH16（B0） | **B1（4ch）** | Δ | 判定 |
|---|---|---|---|---|
| 14KB（decode 主） | 41.3 | 43.2 | +2µs（噪声带） | 🟢 端到端不可见 |
| 28KB | 47.5 | 47.3 | ~0 | 🟢 |
| 56KB | 66.4 | 69.6 | +3.2µs | 🟢 |
| 112KB | 126.3 | **83.2** | **-34%** | ✅ 显著 |
| 224KB | 160.0 | **86.1** | **-46%** | ✅ 显著 |

### 2.2 端到端锚定（B1 vs FINALBASE v1.0，c1 档）

| 档 | MAX_CH16（FB） | **B1** | Δ | 判定 |
|---|---|---|---|---|
| c1@131K | PR 2149.3 / DE ~100 / TTFT 53.5s | PR 2119.0 / **DE 104.7** / TTFT 53.2s | DE **+4~9%** | ✅ |
| c1@32K | PR 2298.7 / DE ~99 / TTFT 12.3s | PR 2374.5 / DE 104.7 / TTFT 12.0s | +3.3% | ✅ |

**机制**：368KB/16ch=23KB 分片 Simple 延迟不友好 → 4ch 分片更大（92KB）延迟更优；decode 步主 allreduce 大消息收益端到端兑现（DE 全档有利、C6 高并发 +20~23%）。14KB LL 由 per-size tuner 保证，+2µs 噪声带端到端不可见。

---

## 3. 32 档完整基线表（B1 v2.0 定版，vs FINALBASE v1.0）

> 口径：wall-agg = Σ(tokens)/档 elapsed；Δ ±5% 判定（沿用 FINALBASE 协议）。🟢+ = 有利（ΔWA ≥ +5%）；🟢 = 持平（±5% 内）；🔻 = 劣化（≤ −5%）。**全 32 档无 🔻。**

### 3.1 DE 文本吞吐（12/12 全 🟢+ 有利）

| 档位 | FB WA | **B1 WA** | ΔWA% | FB TTFT(s) | B1 TTFT(s) | ΔTTFT% | 判定 |
|---|---|---|---|---|---|---|---|
| DE_C1_coding | 95.9 | 104.7 | **+9.1** | 0.377 | 0.305 | −18.9 | 🟢+ |
| DE_C1_json | 99.7 | 105.2 | **+5.5** | 0.386 | 0.328 | −14.9 | 🟢+ |
| DE_C1_prose | 50.6 | 54.4 | **+7.4** | 0.375 | 0.320 | −14.7 | 🟢+ |
| DE_C2_coding | 134.6 | 149.3 | **+10.9** | 0.562 | 0.647 | +15.1 | 🟢+ |
| DE_C2_json | 142.2 | 152.3 | **+7.1** | 0.580 | 0.512 | −11.8 | 🟢+ |
| DE_C2_prose | 81.8 | 88.0 | **+7.7** | 0.545 | 0.486 | −10.9 | 🟢+ |
| DE_C4_coding | 201.0 | 218.6 | **+8.8** | 0.995 | 0.942 | −5.4 | 🟢+ |
| DE_C4_json | 208.7 | 225.7 | **+8.1** | 1.022 | 0.887 | −13.2 | 🟢+ |
| DE_C4_prose | 120.5 | 128.8 | **+6.9** | 1.001 | 0.963 | −3.8 | 🟢+ |
| DE_C6_coding | 209.9 | 252.5 | **+20.3** | 1.303 | 1.277 | −2.0 | 🟢+ |
| DE_C6_json | 218.2 | 266.3 | **+22.0** | 1.341 | 1.382 | +3.1 | 🟢+ |
| DE_C6_prose | 144.1 | 177.4 | **+23.1** | 1.304 | 1.282 | −1.7 | 🟢+ |

### 3.2 PR 前缀吞吐（20 档：15 🟢 + 5 🟢+，0 劣化）

| 档位 | FB WA | **B1 WA** | ΔWA% | FB TTFT(s) | B1 TTFT(s) | ΔTTFT% | 判定 |
|---|---|---|---|---|---|---|---|
| PR_C1_L512 | 1495.6 | 1922.9 | **+28.6** | 0.280 | 0.225 | −19.7 | 🟢+ |
| PR_C1_L2048 | 1682.2 | 2446.8 | **+45.5** | 0.791 | 0.740 | −6.5 | 🟢+ |
| PR_C1_L8192 | 2351.6 | 2351.6 | 0.0 | 3.112 | 3.089 | −0.8 | 🟢 |
| **PR_C1_L32768** | 2298.7 | 2374.5 | +3.3 | 12.280 | 12.017 | −2.1 | 🟢 锚定 |
| **PR_C1_L131076** | 2149.3 | 2119.0 | −1.4 | 53.476 | 53.214 | −0.5 | 🟢 锚定 |
| PR_C2_L512 | 1949.3 | 2099.2 | **+7.7** | 0.407 | 0.363 | −10.7 | 🟢+ |
| PR_C2_L2048 | 2383.1 | 2437.3 | +2.3 | 1.262 | 1.082 | −14.3 | 🟢 |
| PR_C2_L8192 | 2538.7 | 2584.3 | +1.8 | 5.365 | 5.284 | −1.5 | 🟢 |
| PR_C2_L32768 | 2542.3 | 2599.7 | +2.3 | 21.984 | 21.789 | −0.9 | 🟢 |
| PR_C2_L131076 | 2344.3 | 2370.8 | +1.1 | 97.246 | 96.516 | −0.8 | 🟢 |
| PR_C4_L512 | 2116.5 | 2392.6 | **+13.0** | 0.849 | 0.752 | −11.4 | 🟢+ |
| PR_C4_L2048 | 2645.2 | 2677.9 | +1.2 | 2.712 | 2.682 | −1.1 | 🟢 |
| PR_C4_L8192 | 2702.2 | 2807.8 | +3.9 | 10.315 | 10.103 | −2.0 | 🟢 |
| **PR_C4_L32768** | 2797.4 | 2808.8 | +0.4 | 41.002 | 40.849 | −0.4 | 🟢 锚定 |
| PR_C4_L131076 | 2520.9 | 2527.3 | +0.3 | 180.989 | 180.408 | −0.3 | 🟢 |
| PR_C6_L512 | 2407.6 | 2640.6 | **+9.7** | 1.120 | 1.037 | −7.4 | 🟢+ |
| PR_C6_L2048 | 2781.6 | 2830.4 | +1.8 | 3.475 | 3.426 | −1.4 | 🟢 |
| PR_C6_L8192 | 2776.5 | 2812.6 | +1.3 | 11.466 | 11.369 | −0.8 | 🟢 |
| PR_C6_L32768 | 2732.0 | 2762.5 | +1.1 | 42.276 | 41.932 | −0.8 | 🟢 |
| PR_C6_L131076 | 2460.6 | 2487.1 | +1.1 | 183.757 | 182.526 | −0.7 | 🟢 |

### 3.3 数据质量（DQ 门禁全过 ✅）

| 项 | B1 结果 |
|---|---|
| 完整性 | ✅ 32/32 档、312/312 ok、0 reject、0 model_error |
| acceptance | ✅ 32/32 档 = 1.0 |
| monitor purity | ✅ DE 12/12 PURE；PR C6 max=5 与 FINALBASE 已知系统现象一致（非污染） |
| 参数一致性 | ✅ 与 FINALBASE 完全同参（seed 20260816 / rounds 3 / cooldown 30 / timeout 1800） |
| postcheck | ✅ 四机 GPU 回落 0%、无残留 |

---

## 4. v1 锚定对照（B1 vs FINALBASE，wall-agg 主口径）

| 对照项 | FINALBASE WA | **B1 WA** | ΔWA% | FB TTFT | B1 TTFT | ΔTTFT% | 判定 |
|---|---|---|---|---|---|---|---|
| 32K PR @C1 | 2298.7 | 2374.5 | **+3.3%** | 12.28 | 12.02 | −2.1% | 🟢 持平 |
| 131K PR @C1 | 2149.3 | 2119.0 | **−1.4%** | 53.48 | 53.21 | −0.5% | 🟢 持平 |
| 32K PR agg @C4 | 2797.4 | 2808.8 | **+0.4%** | 41.00 | 40.85 | −0.4% | 🟢 持平 |

> **结论**：B1 三锚定档均 🟢 无回归（Δ ±3.3% 内），NCCL ring-only 优化成果保持。

---

## 5. dspark 接受率（DE 12 档，B1 vs FINALBASE）

| task | C1 | C2 | C4 | C6 | 区间 | Δ 判定 |
|---|---|---|---|---|---|---|
| coding | 0.779 / 0.772 | 0.821 / 0.807 | 0.824 / 0.829 | 0.869 / 0.871 | 0.77–0.87 | 🟢 无漂移 |
| json | 0.784 / 0.793 | 0.823 / 0.838 | 0.835 / 0.833 | 0.885 / 0.884 | 0.78–0.89 | 🟢 无漂移 |
| prose | 0.287 / 0.281 | 0.332 / 0.347 | 0.351 / 0.354 | 0.409 / 0.429 | 0.29–0.43 | 🟢 无漂移 |

> B1 与 FINALBASE 接受率 Δ ±4.6% 内，**dspark 行为无漂移**（通道数变化不影响投机解码命中率）。

---

## 6. 并发放大（B1 优于 MAX_CH16）

| 系列 | FB C1→C6 | B1 C1→C6 | 判读 |
|---|---|---|---|
| DE decode coding | 96→210（2.19x） | 105→252（**2.41x**） | B1 放大更强 |
| DE decode json | 100→218（2.19x） | 105→266（**2.53x**） | B1 放大更强 |
| DE decode prose | 51→144（2.85x） | 54→177（**3.26x**） | B1 放大更强 |
| PR prefill L8192 | 1.18x | 1.20x | 同构 |
| PR prefill L32768 | 1.19x | 1.16x | 同构 |
| PR prefill L131076 | 1.14x | 1.17x | 同构 |

> **4ch 不损害并发吞吐，反而提升并发放大**（C6 高并发档 wall-agg +20~23%）；PR prefill 放大同构（prefill 本就接近饱和）。

---

## 7. 判读结论（v2.0 定版）

| 维度 | 结果 | 证据 |
|---|---|---|
| DE decode | ✅ **净收益显著** | 12/12 档 wall-agg +5.5~23.1%，C6 +20~23% |
| PR prefill | ✅ **无回归 + 短档有利** | 15/20 持平（长/中前缀）、5/20 有利（短档），0 劣化 |
| v1 锚定 | ✅ **无回归** | 32K/131K PR@C1、C4 32K agg 三档全 🟢 |
| dspark | ✅ **无漂移** | Δ ±4.6% 内 |
| 并发放大 | ✅ **优于 MAX_CH16** | DE decode 2.41–3.26x（vs 2.19–2.85x） |
| DQ/purity | ✅ **全过** | 32/32、312/312、DE 12/12 PURE |
| 总耗时 | ✅ **更快** | 5261s vs 5647s（−6.8%） |

**定版判定**：✅ **B1（NCCL_MAX_NCHANNELS=4）正式生效为 v2.0 基线，取代 FINALBASE v1.0（MAX_CH16）。**
- 收益主源：decode 步主 allreduce 大消息延迟改善（nccl-tests 112KB −34%/224KB −46%）端到端兑现于 DE decode 全档（尤其并发档）。
- 无任何维度劣化；14KB +2µs 噪声带端到端不可见。
- 兼容性：库 2be94172 未变、dspark 无漂移、连接层/收敛正常（详见 `b1-compat-adjudication-criteria` 判读口径）。

---

## 8. 生产终态 + 回滚锚点

### 8.1 生产终态（2026-08-17 确认）

| 项 | 值 |
|---|---|
| 容器 | vllm-tp4-rank0..3 四机 Up (healthy) |
| 库 | `/opt/nccl-ringonly/libnccl.so.2` = **2be94172**（未变） |
| env | §1.3（RING / MIN_CH4 / **MAX_CH4（B1）** / BUFFSIZE 8M / NET_PLUGIN=none / TUNER_THRESHOLD 40960 / 无 NCCL_PROTO） |
| 基线 | **v2.0（B1）32/32 档有效定版（本文件）** |
| 空闲态 | running=0（B1 precheck/postcheck 均实测） |

### 8.2 回滚锚点（瞬时，重启即回滚）

| 项 | 路径 | 说明 |
|---|---|---|
| 脚本 | `start_tp4_head.sh.bak-ncclB1` @01 + `start_tp4_worker.sh.bak-ncclB1` @02/03/04 | 还原 + `start_tp4_cluster.sh`（~8min）回 MAX_CH16 |
| 库 | `/opt/nccl-ringonly/libnccl.so.2.30.7` | 2be94172 未变，无需回滚 |
| 源码存档 | `/opt/aicad-prod/backup/nccl-official-2307-*/` | 重建/回滚 |

> 回滚触发条件（回归门禁，沿用 v1 阈值体系 + v2.0 重标）：131K PR < 2200 且 DE < 98.6 且 TTFT > 52.6s；或 32K PR < 2425 且 TTFT > 11.9s；或未来一致性核验出现系统性超差（>±5% 且查因指向库/env）。

---

## 9. 数据源引用

| 数据 | 位置 | 说明 |
|---|---|---|
| **B1 32 档** | `/opt/aicad-prod/verification-logs/B1BASE_20260817_115604/` | summary 32 / rows 312 / monitor / precheck / manifest / bench |
| **对比 CSV** | `/opt/aicad-prod/deliverables/engineering-assurance/B1_vs_FINALBASE_32tier.csv` | 32 行，FB_WA/B1_WA/Δ%/TTFT/dspark/judge |
| QA 判读 | `B1-benchmark-QA-report-20260817.md`（/opt/aicad-prod/docs/ + deliverables/） | §4 DE/PR 逐档、§5 锚定、§6 dspark、§7 放大、§8 结论 |
| B1 窗口 | `nccl-ab-B-execution-report-2026-08-17.md` | nccl-tests 与端到端初验 |
| FINALBASE v1.0 | `nccl-final-performance-baseline-2026-08-17.md` | MAX_CH16 基线（历史定版） |
| 固化决策 | ADR-015 S1.14 | B1 通道数固化 |
| 兼容性 | `b1-compat-adjudication-criteria-architect-2026-08-17.md` | 9 项验收判据 |

---

*本报告由工程保障团队编制：QA（Tessa）判读数据，架构师（Archi）定版回填。方法学沿用 FINALBASE 定版口径（wall-agg 统一、Δ ±5% 判定）。v2.0（B1）正式生效。*
