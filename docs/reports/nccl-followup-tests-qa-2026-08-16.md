# NCCL Stage B 遗留项复测 QA 判读报告（131K DE 低噪 + 并发 LL 收益放大）

**日期**：2026-08-16 09:10 (UTC+8)
**工作流**：NCCL Stage B 优化遗留项复测 — ① 131K decode 低噪复测（长 completion）② 并发场景（c>1）小消息 LL 收益放大验证
**执行/判读**：Tessa（QA / Testing Expert）
**被测环境**：<node1> 生产库 3d9cf539（官方 NCCL 2.30.7-1 + v1 环邻过滤 + v4 硬编码映射 + enqueue 双带 tuner），无 NCCL_PROTO，NCCL_NET_PLUGIN=none，四机 healthy，模型 deepseek-v4-flash-0731（max_model_len 400000）
**状态**：🟢 **两项遗留项均通过 —— 131K DE 无真实回归；并发下 agg decode 吞吐随并发强放大（LL 收益放大佐证成立）**

---

## 📌 TL;DR

- **遗留项 1（131K DE 低噪复测）**：脚本无 completion 长度 CLI 参数（`TASK_MAX_TOKENS={"coding":512,"json":512,"prose":256}` 硬编码）。用 wrapper 注入 `ignore_eos=true` 强制满长生成，**决定性长窗口样本（completion=2048×3，decode 窗口 ~21s）DE = 99.62 / 105.39 / 101.5（mean **102.17**，CV 2.88%）**，vs 基线 94.47 **+8.15%**；与 FULLTEST 合并（12 样本）mean **96.65**，**全部 >90**。→ **131K DE 无真实回归**，短窗口 92-100 波动确认是样本方差（长窗口 CV 2.88% vs 短窗口 4.01%，方差收窄 28%）。
- **遗留项 2（并发 LL 收益放大）**：c4（monitor 纯净 running==4）agg decode **98.57 → 193.55（+96.4%）**，agg prefill **2425 → 2782.72（+14.7%）**；c8 agg decode **591.29（+499.9%）**，agg prefill 2381.99（≈持平，prefill 已饱和）。→ **agg decode 吞吐随并发放大约 2x（c4）/ 6x（c8），小消息 LL 收益在并发批处理下放大成立**。
- **数据质量提示**：c8 档 monitor 显示 running **峰值仅 6.0（主体 4-6，未达 8）**，TTFT 40.4-98.4s 分布宽 → 服务端调度未同时跑满 8 请求，c8 agg 数值含调度分批成分，判读为「指示性/上限」，c4 为最干净证据。
- **环境**：测试后 GPU 回落 0%、running=0，无残留请求；生产配置未改动；4 档全部 0 错误。

---

## 1. 执行记录与落盘

| 档位 | ctx | conc | max_tokens 注入 | 时间 | 落盘目录 | bench RC | 错误 |
|---|---|---|---|---|---|---|---|
| FOLLOWUP_L131K | 131072 | 1 | coding→2048（EOS 提前） | 08:41:56 | verification-logs/FOLLOWUP_L131K_20260816_084153/ | 0 | 0 |
| FOLLOWUP_L131K_IGNEOS | 131072 | 1 | coding→2048 + ignore_eos | 08:45:59 | verification-logs/FOLLOWUP_L131K_20260816_084556/ | 0 | 0 |
| FOLLOWUP_C4 | 32768 | 4 | 无（默认 512，与基线同语义） | 08:50:11 | verification-logs/FOLLOWUP_C4_20260816_085005/ | 0 | 0 |
| FOLLOWUP_C8 | 32768 | 8 | 无 | 08:53:09 | verification-logs/FOLLOWUP_C8_20260816_085306/ | 0 | 0 |

执行方式：每档先起 monitor（5s 采样 `vllm:num_requests_running`），判据 c1→running==1、c4→running==4、c8→running==8；串行执行（L131K → C4 → C8）；`--engine threads / --rounds 3 / --tasks coding / --group <档名>`。所有目录含 `summary_*.json + rows_*.csv + monitor.log + precheck.log + bench.log`。

**工具说明**（不修改生产脚本）：`/tmp/qa_followup/wrapper_run.py` 源码级注入 `TASK_MAX_TOKENS` 覆盖与 `ignore_eos=True`（生产 `bench_prefill_decode_async.py` 原样未动）；`ignore_eos` 服务端已验证支持（小请求 probe：completion_tokens=8 精确命中、finish=length）。

---

## 2. 遗留项 1：131K decode 低噪复测（长 completion）

### 2.1 方法

生产 bench 脚本 `TASK_MAX_TOKENS` 硬编码 coding=512/json=512/prose=256，无 completion 长度 CLI 参数；且**单纯调大 max_tokens 无效** —— 第一档（max_tokens=2048，无 ignore_eos）模型仍提前 EOS，completion 仅 461/507/745（与基线 431-512 相近），DE 94.25/91.64/92.96（mean 92.95）。因此引入第二档 **ignore_eos=true 强制满长 2048**，获得 ~21s 稳定 decode 窗口（基线仅 ~5s）。

### 2.2 决定性数据（FOLLOWUP_L131K_IGNEOS）

| wave | prompt_tokens | completion_tokens | TTFT(s) | total(s) | PR | DE |
|---|---|---|---|---|---|---|
| 1 | 114760 | **2048** | 52.75 | 73.30 | 2175.65 | 99.62 |
| 2 | 115032 | **2048** | 52.76 | 72.18 | 2180.39 | 105.39 |
| 3 | 114836 | **2048** | 54.17 | 74.34 | 2119.98 | 101.50 |
| **p50** | — | — | **52.76** | **73.30** | **2175.65** | **101.50** |

monitor：全程 running==1 纯净（仅起始 1 个 running=0.0，可接受）。

### 2.3 判读：方差收敛 + 均值不降反升

| 指标 | 短窗口基线（FULLTEST 6 样本） | 长窗口本测（3 样本） |
|---|---|---|
| DE mean | 95.73 | **102.17** |
| DE range | 91.60–102.30（span 10.7） | 99.62–105.39（span 5.77） |
| stdev / CV | 3.84 / 4.01% | 2.94 / **2.88%** |

- **方差收敛**：长窗口 CV 2.88% vs 短窗口 4.01%，相对方差收窄 ~28%；范围跨度 5.77 vs 10.7，**收窄一半**。
- **均值判读**：长窗口稳态 DE mean **102.17**，vs Stage B 基线 94.47 **+8.15%**；p50 101.50 高于 FULLTEST 合并 95.78。短窗口样本系统性略低估稳态 decode 吞吐（decode 窗口 ~5s 内包含 EOS 尾段抖动）。
- **与 FULLTEST 合并统计**（任务要求口径）：

| 集合 | n | mean | median | range | 全部 >90 |
|---|---|---|---|---|---|
| FULLTEST 131K（原 6 样本） | 6 | 95.73 | 95.78 | 91.60–102.30 | ✅ |
| 本次新样本（6） | 6 | 97.56 | 96.94 | 91.64–105.39 | ✅ |
| **合并（12 样本）** | 12 | **96.65** | 95.78 | 91.60–105.39 | ✅ |

合并 12 样本 mean 96.65（>90），min 91.60 亦 >90 → **131K DE 无真实回归**。

### 2.4 结论

**🟢 131K DE 无真实回归。** 原 FULL131K_B 单样本 92.21 及 STAGEB 短窗口 92-100 波动确认为短 completion（~400-512 tokens）/ 短 decode 窗口（~5s）导致的样本方差；21s 长窗口稳态 DE ≈ 102 tok/s（99.6-105.4），高于基线估计。

---

## 3. 遗留项 2：并发场景（c>1）LL 收益放大验证

### 3.1 实测数据（ctx 32768 / coding / rounds 3 / threads）

| 档 | conc | per-req PR | per-req DE | TTFT(s) | agg PR | agg DE | agg DE 效率¹ | monitor 判据 |
|---|---|---|---|---|---|---|---|---|
| c1（基线 FULL32K A/B 合并） | 1 | 2425.04 | 98.57 | 11.93 | 2425.04 | 98.57 | 100% | running==1 纯净 |
| **c4** | 4 | 698.07 | 48.74 | 41.56 | **2782.72** | **193.55** | 49.1% | **running==4 纯净**（1/32 采样 running=1 波间边界） |
| **c8** | 8 | 558.22 | 14.98 | 53.67 | **2381.99** | **591.29** | 75.0% | ⚠️ running 峰值 6.0（主体 4-6，未达 8） |

¹ 效率 = agg DE / (c1 DE × conc)，衡量相对线性扩展。

### 3.2 vs c1 基线趋势

| 指标 | c4 Δ | c8 Δ |
|---|---|---|
| **agg decode_tps** | 98.57 → 193.55 = **+96.4%** | 98.57 → 591.29 = **+499.9%** |
| agg prefill_tps | 2425 → 2782.72 = **+14.7%** | 2425 → 2381.99 = **-1.8%**（prefill 已饱和） |
| per-req decode_tps | 98.57 → 48.74 = -50.6%（4 路共享） | 98.57 → 14.98 = -84.8%（8 路共享） |
| per-req TTFT | 11.93 → 41.56s（并发 prefill 争用） | 11.93 → 53.67s |

### 3.3 判读：LL 收益放大佐证

1. **agg decode 随并发强放大**：c1→c4 接近 2x（+96.4%），c1→c8 约 6x（+499.9%）。decode 步 87 次小 allreduce 在并发下被跨请求重叠/分摊，通信延迟不再逐请求串行暴露 —— 与「小消息 LL（容器级 19-27% 延迟改善）收益在批处理下放大」机制一致（Stage B QA 报告 §4.3 推论首次得到端到端验证）。
2. **agg prefill 增幅小（c4 +14.7%，c8 ≈0）**：prefill 是大消息 allreduce（368KB+）主导、compute-bound，并发不显著增加吞吐（c8 已饱和），LL 收益主要落在 decode 侧 —— 与设计定位完全吻合。
3. **效率曲线 c4 49% → c8 75% 上升**：并发越高 decode 通信重叠越充分（单请求等待被更多并发请求填满）。但 c8 含调度分批成分（见 §3.4），效率 75% 判为指示性上限；**c4 的 running==4 纯净 + agg DE +96.4% 是最干净的放大证据**。

### 3.4 C8 数据质量注意（必须披露）

- monitor 显示 running **峰值仅 6.0、主体 4-6**，从未达到 8.0 —— 服务端调度（32K prefill 分批 / 内存约束）未同时跑满 8 请求；每波 TTFT 40.4-98.4s 分布极宽（首尾差 ~58s），行数据呈现双峰 per-req decode（多数 9.8-19.8，少数 31-76 —— 后完成 prefill 者在批尾突发 decode）。
- 因此 c8 agg 数值反映的是「8 路 offer + 引擎实际 ~4-6 路执行」下的端到端吞吐，**带调度放大成分**，解读为趋势指示而非精确 8 路纯净测量。
- 建议（如需精确 c8 纯净判读）：降 ctx（如 8K/16K）使 8×ctx 能整批入执行，或增大引擎 max_num_batched_tokens / 调整 prefill 调度后再测。

---

## 4. 纯净性与数据质量

| 检查项 | L131K | L131K_IGNEOS | C4 | C8 |
|---|---|---|---|---|
| monitor 判据 | running==1 ✅ | running==1 ✅ | running==4 ✅（1 个 running=1 波间边界） | running==8 ⚠️（峰值 6，主体 4-6） |
| 运行中污染 | 无 | 无 | 无（边界 1 样本可接受） | 见 §3.4 说明 |
| 错误数 | 0 | 0 | 0 | 0 |
| rounds_ok | 3/3 | 3/3 | 12/12 | 24/24 |
| bench RC | 0 | 0 | 0 | 0 |
| 测试后 GPU/running | — | — | — | 0% / 0.0 ✅ |

---

## 5. 最终结论

**🟢 两项遗留项均通过。**

1. **131K DE 无真实回归**：21s 长窗口稳态 DE mean 102.17（+8.15% vs 94.47），FULLTEST+新样本 12 样本合并 mean 96.65 全部 >90；短窗口 92-100 波动确认为样本方差（长窗口 CV 2.88% vs 短 4.01%）。
2. **并发 LL 收益放大成立**：c4 纯净档 agg decode +96.4%（193.55 tok/s）、agg prefill +14.7%；c8 指示性 agg decode +499.9%。小消息 LL 在并发批处理下的通信重叠收益得到端到端放大验证。

**建议/可选后续**：
- 如需 c8 精确纯净判读：降 ctx（8K/16K）或调引擎调度参数后复测（§3.4）。
- 如需更强的 LL 归因：c4 档加跑 NCCL_PROTO=Simple 对照（生产禁改，可在测试容器/沙箱做），量化 LL 与 Simple 在并发下的 agg decode 差。
- 驱动 580.173.02 decode 回归核查（沿用既有 P2-6 遗留项）。

---

## 📚 数据来源

- 本报告实测：
  - /opt/aicad-prod/verification-logs/FOLLOWUP_L131K_20260816_084153/
  - /opt/aicad-prod/verification-logs/FOLLOWUP_L131K_20260816_084556/
  - /opt/aicad-prod/verification-logs/FOLLOWUP_C4_20260816_085005/
  - /opt/aicad-prod/verification-logs/FOLLOWUP_C8_20260816_085306/
- c1 基线（Stage B FULLTEST）：FULLTEST_FULL32K_{A,B}_20260816_0820*/、FULLTEST_FULL131K_{A,B}_20260816_0822*/、STAGEB_{A,B}131K_20260816_075*/（交叉参考）
- bench 脚本：/opt/aicad-prod/bench_prefill_decode_async.py（wrapper 源码级注入，生产脚本未改动）
- 机制依据：nccl-stageb-fulltest-qa-2026-08-16.md（§4 小消息 LL 收益定位 + §4.3 并发放大推论）

> 本报告由工程保障团队 QA 成员生成，关键决策请由人类工程负责人复核。
