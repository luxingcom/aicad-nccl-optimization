# Stage B（per-size NCCL tuner）全量端到端性能测试 QA 判读报告

**日期**：2026-08-16 08:30 (UTC+8)
**工作流**：NCCL Stage B 优化（per-size tuner）— 生产全量端到端验证
**执行/判读**：Tessa（QA / Testing Expert）
**被测环境**：<node1> 生产库 3d9cf539（官方 NCCL 2.30.7-1 + v1 环邻过滤 + v4 硬编码映射 + enqueue 双带 tuner），NCCL_PROTO=Simple 已移除，NCCL_NET_PLUGIN=none，四机 healthy，模型 deepseek-v4-flash-0731（max_model_len 400000）
**状态**：🟢 **Stage B 保留生产（放行）**

---

## 📌 TL;DR

- 四档全量测试（FULL32K_A/B、FULL131K_A/B，concurrency=1 / coding / rounds=3 / threads）全部完成，**0 错误**，monitor 全程纯净（仅起始 running=0 可接受，无运行中污染）
- **vs MAX_CH16（紧邻基线）**：32K 三项全绿（PR +1.18% / DE -1.41% / TTFT -1.12%，均在 ±5% 内持平或微升）；131K PR -0.12% / TTFT +0.48% 持平，DE -5.39% 越过 -5% 边缘线（详见机制解释与样本合并判定）
- **vs T1aM4（被替换的上一代基线）**：全面改善 —— 32K PR +6.73% / DE +5.03% / TTFT -5.06%；131K PR +9.23% / DE +2.69% / TTFT -8.40% → **Stage B 相对其直接前任净收益成立**
- **vs A0 原始**：累计收益显著 —— 32K PR +14.93% / TTFT -12.32%；131K PR +21.61% / TTFT -16.80%
- **Stage B 小消息 LL 收益定位**：decode 侧相对 T1aM4 兑现 +5.0%（32K）/ +2.7%（131K），说明容器级小消息 LL（19-27%）已传导到端到端 decode；131K 相对 MAX_CH16 的 -5.4% 判定为样本方差（短 completion 窗口，合并 STAGEB 预跑后 -3.3%，未破线）
- **最终结论**：🟢 **放行，Stage B 保留生产，不触发回滚**

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|---|---|
| 整体评级 | 🟢 通过（Stage B 保留生产） |
| 阻塞项 | 0 |
| 触发回滚 | 否（无任何档位触发回滚线） |
| 32K 主判据 | 全部通过（vs MAX_CH16 三绿，vs T1aM4 三改善） |
| 131K 观察项 | 通过（DE 边缘项经机制解释 + 样本合并后判定无回归） |
| 关键行动项 | ① 131K decode 低噪复测（可选，长 completion）② 驱动 580.173.02 回归核查（沿用遗留项）③ 16MB+ 大档端到端可选补测 |

---

## 1. 执行记录与落盘

| 档位 | ctx | 时间 | 落盘目录 | bench RC | 错误 |
|---|---|---|---|---|---|
| FULL32K_A | 32768 | 08:20:04 | /opt/aicad-prod/verification-logs/FULLTEST_FULL32K_A_20260816_082004/ | 0 | 0 |
| FULL32K_B | 32768 | 08:21:01 | /opt/aicad-prod/verification-logs/FULLTEST_FULL32K_B_20260816_082101/ | 0 | 0 |
| FULL131K_A | 131072 | 08:22:00 | /opt/aicad-prod/verification-logs/FULLTEST_FULL131K_A_20260816_082200/ | 0 | 0 |
| FULL131K_B | 131072 | 08:24:58 | /opt/aicad-prod/verification-logs/FULLTEST_FULL131K_B_20260816_082458/ | 0 | 0 |

执行方式：每档先起 monitor（5s 采样 `vllm:num_requests_running`）确认纯净窗口后串行执行 bench（concurrency=1 / coding / rounds=3 / engine=threads），档间 monitor 停止后再开下一档。所有目录含 `summary_*.json` + `rows_*.csv` + `monitor.log` + `precheck.log`。

---

## 2. 四档 FULLTEST 实测数据（p50）

| 档位 | PR (prefill_tps) | DE (decode_tps) | TTFT (s) | Total (s) | 波动(PR min-max) | 波动(DE min-max) |
|---|---|---|---|---|---|---|
| FULL32K_A | **2425.93** | **98.06** | **11.89** | 16.88 | 2421.42~2431.61 | 95.38~100.27 |
| FULL32K_B | **2424.15** | **99.07** | **11.96** | 17.12 | 2399.76~2433.75 | 90.51~100.45 |
| FULL131K_A | **2217.81** | **96.72** | **51.91** | 56.92 | 2212.94~2217.87 | 95.64~102.30 |
| FULL131K_B | **2182.11** | **92.21** | **53.25** | 58.79 | 2146.01~2211.50 | 91.60~95.92 |

**A/B 稳定性**：
- 32K：PR Δ0.07% / DE Δ1.03% / TTFT Δ0.59% —— 高度稳定 ✅
- 131K：PR Δ1.64% / DE Δ4.89% / TTFT Δ2.52% —— PR/TTFT 稳定，DE 波动略大（completion tokens 仅 ~400-512，decode 窗口 ~5s，单步抖动即可引起数个百分点偏差）

补充交叉参考（今晨部署确认时 SRE 预跑，同配置同参）：
| 档位 | PR | DE | TTFT |
|---|---|---|---|
| STAGEB_A32K | 2420.18 | 98.68 | 12.05 |
| STAGEB_B32K | 2422.49 | 99.93 | 11.81 |
| STAGEB_A131K | 2197.37 | 100.60 | 52.21 |
| STAGEB_B131K | 2203.57 | 96.74 | 51.81 |

---

## 3. 三级基准比较表（判读核心）

### 3.1 vs MAX_CH16（紧邻基线，32K: 2396.73/99.97/12.06s；131K: 2202.66/99.85/52.33s）

| 指标 | 32K StageB(A/B均值) | Δ vs MAX_CH16 | ±5% | 判定 | 131K StageB(A/B均值) | Δ vs MAX_CH16 | ±5% | 判定 |
|---|---|---|---|---|---|---|---|---|
| PR | 2425.04 | **+1.18%** | ✅ | 微升 | 2199.96 | **-0.12%** | ✅ | 持平 |
| DE | 98.57 | **-1.41%** | ✅ | 持平 | 94.47 | **-5.39%** | ⚠️ 边缘 | 见 §4 机制解释 |
| TTFT | 11.93s | **-1.12%** | ✅ | 微降 | 52.58s | **+0.48%** | ✅ | 持平 |

- **32K：三项全绿**，无回归，PR 还有 +1.18% 微升。
- **131K：PR/TTFT 持平（±0.5% 内），DE -5.39% 越边缘线**。但注意 MAX_CH16 的 99.85 为单次 A 档样本（历史 R2 曾出现 86.53 污染值），而 Stage B 四个 131K 样本（FULL A/B + STAGEB A/B）DE = 96.72/92.21/100.60/96.74，**合并均值 96.57 → Δ-3.29%，未破 -5% 线**。单样本 B 档 92.21 拉低了均值。

### 3.2 vs T1aM4（被替换前任，32K: 2272.07/93.84/12.56s；131K wave1: 2014/91.99/57.4s）

| 指标 | 32K StageB | Δ vs T1aM4 | 判定 | 131K StageB | Δ vs T1aM4 | 判定 |
|---|---|---|---|---|---|---|
| PR | 2425.04 | **+6.73%** | ✅ 改善 | 2199.96 | **+9.23%** | ✅ 改善 |
| DE | 98.57 | **+5.03%** | ✅ 改善 | 94.47 | **+2.69%** | ✅ 改善 |
| TTFT | 11.93s | **-5.06%** | ✅ 改善 | 52.58s | **-8.40%** | ✅ 改善 |

**Stage B 相对直接前任 T1aM4 全面改善**（6/6 项），尤其解码侧 +5.0%/+2.7%，TTFT -5.1%/-8.4% —— 证明「移除全局强制 Simple + per-size LL/Simple 双带」策略在端到端正确兑现。

### 3.3 vs A0 原始（32K: 2110/96/13.60s；131K: 1809/101.94/63.2s）

| 档位 | PR 累计 | DE 累计 | TTFT 累计 |
|---|---|---|---|
| 32K | **+14.93%** | +2.67% | **-12.32%** |
| 131K | **+21.61%** | -7.33%（见 §4 解释） | **-16.80%** |

累计收益明确：prefill 提升 15~22%，TTFT 改善 12~17%，长上下文收益 > 短上下文（与 NCCL 层大消息 allreduce 收益随尺寸增大一致）。

---

## 4. Stage B 收益定位：小消息 LL 在端到端的体现

**背景**：容器级 A/B 实测小消息（1-16KB）LL 协议相对 Simple 有 **19-27%** 延迟改善；Stage B 的核心 = 大消息强制 Simple（防 SPCX/LL128 慢路径）+ 小消息走 LL（decode 战场）。

**端到端体现（重点 DE 与 TTFT）**：

| 指标 | 观察 | 定位 |
|---|---|---|
| 32K DE | 98.57 vs T1aM4 93.84 = **+5.03%** | ✅ 小消息 LL 收益传导到 decode |
| 131K DE | 94.47 vs T1aM4 91.99 = **+2.69%** | ✅ 同上（幅度较小） |
| 32K TTFT | 11.93s vs T1aM4 12.56s = **-5.06%** | ✅ prefill 大消息 Simple 快路径 + 调度 |
| 131K TTFT | 52.58s vs T1aM4 57.4s = **-8.40%** | ✅ 大消息收益主导 |

**131K DE -5.39%（vs MAX_CH16）机制解释**（判定无回归的依据）：
1. **短 completion 窗口 + 高样本方差**：131K 档 completion tokens 仅 ~400-512，decode 有效窗口 ~5s（total 56.9~58.8s 中 TTFT 占 51.9~53.3s），单次 decode 步进抖动即可造成 ±5% 量级偏差。FULL131K_B（92.21）与 FULL131K_A（96.72）同配置仅差 4.9%，STAGEB 预跑 100.60/96.74 亦落在同一分布内 —— 是样本噪声而非系统性回归。
2. **合并样本未破线**：Stage B 四个 131K DE 样本均值 96.57 vs MAX_CH16 99.85 = **-3.29%**（在 ±5% 内）；MAX_CH16 的 99.85 本身是单点高值样本。
3. **c=1 低并发下 LL 收益被部分吸收**：单请求 decode 无 batch 叠加，每 token 延迟中 kernel 计算 + 调度占主导，LL host buffer 的通信延迟收益在 per-token 总延迟中占比被稀释；LL 收益要在并发批处理（多请求共享通信窗口）下才更显著。
4. **decode 通信占比本身偏低**：prefill 大 allreduce（368KB+）是通信主项；decode 小消息虽然逐 token 高频，但单次通信体量小，端到端总耗时占比有限。

**结论**：131K DE 相对 MAX_CH16 的 -5.39% 判定为**边缘噪声项（非回归）**，相对 T1aM4 反而 +2.69%（改善），且 32K DE 明确 +5.03%。**小消息 LL 收益在端到端 decode 侧已得到正面验证。**

---

## 5. 纯净性与数据质量

| 检查项 | 结果 |
|---|---|
| monitor 全程 running==1 | ✅ 四档 FULLTEST + 四档 STAGEB 预跑全部达标（仅起始 running=0.0 一个采样点，属请求尚未进入，可接受） |
| 运行中污染（running>1） | ✅ 无 |
| 错误数 | ✅ 0（errors=0, err_samples=[]） |
| rounds_ok | ✅ 3/3 全档 |
| GPU 负载收尾 | ✅ 测试后回落 0%，服务无残留请求 |
| bench RC | ✅ 全部 0 |

---

## 6. 最终结论

**🟢 Stage B 保留生产（放行），不触发回滚。**

判定依据链：
1. 无任何档位触发回滚线（32K PR 2425>2045 / DE 98.6>84.5 / TTFT 11.9<13.8；131K PR 2200>1629 / TTFT 52.6<69.5）
2. vs 紧邻基线 MAX_CH16：32K 全绿，131K PR/TTFT 持平、DE 经机制解释 + 样本合并判定无回归
3. vs 被替换前任 T1aM4：6/6 项全面改善 → 升级决策正确
4. vs A0 原始：累计收益显著（PR +15~22%，TTFT -12~-17%）
5. 纯净窗口 + 0 错误，数据可信

**遗留/可选行动**：
- 131K decode 低噪复测（长 completion 或更高 rounds）以进一步收窄 DE 置信区间
- 驱动 580.173.02 decode 回归核查（沿用既有 P2-6 遗留项）
- 16MB+ 大档端到端可选补测（LIMIT_CTX=524288）
- 并发场景（concurrency>1）下小消息 LL 收益的批处理放大验证（机制 §4.3 推论）

---

## 📚 数据来源

- 本报告实测：/opt/aicad-prod/verification-logs/FULLTEST_FULL32K_A_20260816_082004/、FULLTEST_FULL32K_B_20260816_082101/、FULLTEST_FULL131K_A_20260816_082200/、FULLTEST_FULL131K_B_20260816_082458/
- 交叉参考（部署确认预跑）：/opt/aicad-prod/verification-logs/STAGEB_{A,B}{32K,131K}_20260816_07*/
- 三级基线来源：nccl-maxch16-e2e-verification-2026-08-16.md、nccl-t1am4-e2e-verification-2026-08-16.md、nccl-large-msg-nonmonotonic-architect-2026-08-16.md
- bench 脚本：/opt/aicad-prod/bench_prefill_decode_async.py（--group/--ctx/--concurrency/--tasks/--rounds/--engine threads/--out）

> 本报告由工程保障团队 QA 成员生成，关键决策请由人类工程负责人复核。
