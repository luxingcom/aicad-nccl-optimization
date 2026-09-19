# V5-ar2 模块（ringonly V5）文档与交付说明

> 来源：dgxspark01 `~/sparkring-kit/ringonlyV5/`（2026-09-04 定版，已晋升生产）。
> 版本链与消歧见 [`../VERSION-LANDSCAPE.md`](../VERSION-LANDSCAPE.md)。

## 快速导读

| 想了解 | 读 |
|---|---|
| **交付物清单与指纹、生产行为、回滚开关** | `DELIVERY.md`（入口，先读） |
| 架构与形态（hook 分发条件、fence-arm、降级） | `ARCHITECTURE.md` + `PROTOCOL.md` |
| API 与算法 | `API.md` + `ALGORITHMS.md` |
| 构建与测试 | `BUILD-TEST.md` |
| E2E 窗口验证（四端 armed / A/B 同窗持平） | `E2E-REPORT-20260904.md` |
| R3 多 QP 负结果 | `R3-REPORT-20260904.md` |
| 审计轮 | `AUDIT-REPORT.md` |
| 后续路线（图内集成） | `INTEGRATION-ROADMAP.md` + `OPEN-ISSUES.md` |
| 踩坑与错误模型 | `PITFALLS.md` + `ERROR-MODEL.md` |
| 库 md5 血统 | `V5-MD5-RECORD.txt` |

## 源码与工具

- ar2 引擎源码：[`../../src/ar2-engine/`](../../src/ar2-engine/)（`ar2_core.cpp` / `ar2_dev_cpu.cpp` / `ar2_dev_cuda.cu` / `ar2_internal.hpp` / `ar2.h`）
- NCCL hook 补丁（256 行，基于 hardened 2307 git 0dd44cd）：[`../../patches/nccl-ringonly-v5-hook.patch`](../../patches/nccl-ringonly-v5-hook.patch)
- 探针与自测工具：[`../../tools/ar2/`](../../tools/ar2/)（`ar2_probe.cu` / `ar2_selftest.cpp` + 窗口脚本 `run_reg.sh` / `run_s2.sh` / `run_win.sh`）
- 同窗 A/B 结果（PR 20 档 + DE 12 档，中位差 -0.11%/+0.78% = 持平）：[`../../results/v5-ab-window/`](../../results/v5-ab-window/)

## 核心事实卡

- **分发条件①~⑧**：bf16 / ncclSum / 就地 / nRanks=4 / 16≤B≤crossover(8192, env `AR2_CROSSOVER_B` 钳 ≤65536) / 16 对齐 / group 规则 v3 / 捕获守卫+锁存
- **启动安全**：捕获期不分发；捕获后首个大 AR 触发四 rank 控制面栅栏武装（10s deadline）；失败=永久全原生
- **优雅降级**：ar2 op 失败 → 永久禁用 + 本 op 原生重做，绝不抛错击穿调用方
- **回滚**：env `AR2_V5=0` 一键全原生（软）；镜像回退还原 `.bak-v5prod-20260904`（硬，分钟级）
- **结构性定谳**：生产 decode AR 在 CUDA graph 重放内不经 hook ⇒ hook 型稳态收益 ≈ 0；收益方向 = 图内集成（vLLM patch 级，未开工）

## 脱敏声明

本目录文件来自服务器原始归档，入库时已将用户名/家目录占位化（`<user>`）；其余内容保持原样。
