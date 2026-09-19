# NCCL ringonly V5 模块 — 交付说明（v1.0.0，2026-09-04 定版）

> 命名约定：**NCCL ringonly V5 模块**（本包）= 按尺寸路由小消息 allreduce 到 ar2 引擎的 NCCL 定制集成；
> **baked-v6 测试镜像** = 另一验证产物（已裁决不晋升）。禁裸用 "V5/V6"。

## 1. 交付物清单与指纹

| 物件 | 位置 | md5 |
|---|---|---|
| libnccl.so.2（V5 hook，2.30.7） | `~/v5libs/` 四机一致 | `36c26ab6` |
| libar2.so.1（ar2 引擎 + fence） | `~/v5libs/` 四机一致 | `343bea89` |
| ar2 引擎源码 + 文档十件套 | `~/sparkring-kit/ringonlyV5/` | 源码包 `aaa84d84`（1.0.0-src-20260904.tar.gz） |
| NCCL hook 源码树（hardened 2307 + V5） | `~/sparkring-kit/nccl-ringonly-v5/` | git 0dd44cd + 本包 `nccl-ringonly-v5-hook.patch`（256 行） |
| V5 生产镜像（容器内集成） | registry `...:LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring-V5` digest `81a0c910` | libnccl `4d8ebaaf` + libar2 `343bea89`，**已晋升生产** |

构建命令（baked 镜像容器内，镜像无 cmake）：见 `docs/BUILD-TEST.md` §"2026-09-04 V5 正式版构建与验收"。

## 2. 形态与行为

- 分发条件①~⑧（`nccl-ringonly-v5/src/collectives.cc` 头注释）：bf16/ncclSum/就地/nRanks=4/
  16≤B≤crossover(8192, env AR2_CROSSOVER_B, 钳 ≤65536)/16 对齐/group 规则 v3/捕获守卫+锁存。
- **fence-arm 启动安全**：捕获期不分发；捕获后首个大 AR 触发四 rank 控制面栅栏（'F'/'G'/'N'，
  共享 10s deadline）武装；失败=永久全原生。稳态 SPMD 锁步分发。
- **优雅降级**：ar2 op 失败 → 永久禁用 + 本 op 原生重做（绝不抛错击穿调用方）。
- 回滚开关：env `AR2_V5=0`（一键全原生）；`AR2_V5_EAGER=1`（无图测试负载逃生门）。
- 观测：atexit 计数（dispatched/failed）+ 每 65536 op progress 报点 + `AR2_V5_HISTOGRAM=1`
  尺寸直方图（捕获期 vs 武装后 eager 分桶，#10 可行性输入）。

## 3. 已验证矩阵（详见 docs/E2E-REPORT-20260904.md）

- 微基准：≤8KB ar2 领先 9~43%（512B -43% / 4KB -19% / 8KB -9%），crossover=8192B 定界。
- wtest 四机：dispatched=1105 全量分发 + 正确性 ok=1（含 EAGER 路径）。
- E2E（fence-arm 版）：四端 armed、dspark 捕获 11/11 零事故、health=200、冒烟正确。
- 同窗 A/B（PR 20 档 + DE 12 档全绿）：PR 中位 -0.11% / DE 中位 +0.78% = **持平**。
- 定版审计轮：三子代理交叉审计（A/B/C 组，FAIL 1 + WARN 若干全修复），CPU selftest 10/10。
- **结构性定谳**：生产 decode 通信在 CUDA graph 重放内不经 hook（<65536 op vs 理论 ~5.8M）、
  prefill AR 全 >crossover ⇒ **hook 型集成稳态收益 ≈ 0（与 ar2 性能无关）**。

## 4. 后续集成路线（摘要，全文见 docs/INTEGRATION-ROADMAP.md）

捕获期集成（OPEN-ISSUES #10）：在 vLLM cudagraph 捕获点为小 AR 集合显式调用
`ar2_capture_layer`（M2 图模式：捕获时固化 kernel，replay 时 CPU 补发 2 WR/op），
把 ≤8KB 人群的 9~43% 微基准收益搬进 decode 步。属 vLLM patch 级工程，前置可行性分析
（捕获期 AR 尺寸直方图 = V5-HISTO 已内建）完成后实施。

## 5. V5 生产镜像（容器内集成形态）

- 基座：registry R5 tag（LuZ0.4.5-...-TP4-Ring-baked，原镜像）。
- 容器内集成：`/opt/nccl-ringonly/libnccl.so.2` ← V5 hook 版（同路径替换，生产脚本零改动）；
  `/opt/ar2/lib/libar2.so.1` + ldconfig；ENV 烘焙 AR2_PEERS/AR2_DEV0/AR2_DEV1/AR2_CTRL_PORT=9520/
  AR2_CROSSOVER_B=8192/AR2_V5_HISTOGRAM=1。
- 验收（2026-09-04 完成）：health=200 + 四端 armed（捕获静默窗后栅栏触发，零事故）+
  捕获期直方图定格（≤8KB 164 op 在图内）+ 冒烟正确 + PR 采样 4 档全绿。
- **已晋升生产**：四机 start 脚本 R5= 指向 V5 tag（备份 .bak-v5prod-20260904）。
- 回滚：env AR2_V5=0（软，一键全原生）；镜像回退 = 还原脚本 .bak-v5prod + guard 重启（硬，分钟级）。

## 6. 归档与血统

- 历史源码/窗口资料：`~/sparkring-kit/archive-20260904/`（s2、build、build235、proto、window-20260903）。
- 中间版血统：libnccl 56028064（捕获守卫）→ a1a9f6b1（降级）→ ac2525a0（fence-arm，E2E 验证版）
  → 36c26ab6（审计定版） → **4d8ebaaf（生产镜像定版, +捕获静默窗）**；libar2 b0950664 → 7c59b387 → **343bea89（定版）**。
- E2E 窗口全程报告：docs/E2E-REPORT-20260904.md；审计：docs/AUDIT-REPORT.md 第二轮。

## 2026-09-04 补充: R1/R2/R3 通讯优化执行轮（容器内集成路线落地）

- **R1 按图归属细分**：完成。164 个 ≤8KB 捕获 op = 77 dspark 辅助 op（≤4KB）+ 87 目标图辅助 op
  （4-8KB）；400-token 解码探针零 eager 调用 → 解码层 AR 确认在 FULL graph replay 内。
- **R2 Route D**：门禁失败（dspark 仅 77/164 且其层 AR 为 114KB+）→ 按路线图自身条件跳过。
- **R3 多 QP 带宽工程**：实现+验证完成, **负结果定谳**（nqp=1/2/4 全档无带宽收益; 单 QP 已饱和,
  大消息劣势是 2 轮阻塞协议串行化）→ crossover 维持 8192, R3 库不晋升生产。报告:
  docs/R3-REPORT-20260904.md; 路线图定谳: docs/INTEGRATION-ROADMAP.md §4.1。
- **生产状态**：R1-diag 镜像 `d118ceb2`（libnccl `51e36db5` + libar2 `343bea89`, fence-arm 生效）
  持续在役; timer/proxy 已恢复; 四机 ~/v5libs 与生产对齐。后续若换窗可顺带评估 R3 库的
  defaults env 修复随窗带入（对未设 env 方零行为差）。
- **后续唯一数量级正确的收益方向**：图内集成（层 AR 固化进 CUDA graph, M2/ar2_capture_layer 深化,
  vLLM patch 级）——需另立窗口设计。
