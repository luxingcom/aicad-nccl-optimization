# ringonly 版本链总览与「V5」消歧（必读）

> **背景**：客户部署实录驱动 v1.1 组件化改造时，仓库索引中 2-hop 被标注为「⛔ 归档（否定结论）」但缺执行层证据，且「ringonly V5」曾在两套不同语境下使用。本文以 2026-09-19 服务器取证（dgxspark01）为准，梳理完整版本链并消歧。

## 1. 「V5」一词的三种语义（严格区分）

| 名称 | 本体 | 状态 | 本文位置 |
|---|---|---|---|
| **V5-ar2 模块**（ringonly V5 模块） | NCCL hook 集成：按尺寸把小消息 allreduce 分发到 **ar2 引擎**（2 轮 ring allreduce，含 fence-arm 启动安全、优雅降级） | ✅ **2026-09-04 定版并晋升生产**（V5 镜像 digest `81a0c910`，在役为 R1-diag `d118ceb2`：libnccl `51e36db5` + libar2 `343bea89`） | [`docs/v5-ar2/`](../v5-ar2/DELIVERY.md) |
| **v5-netdev-configurable.patch**（本仓库 v1.1 新增） | 运行期可配置 per-peer 设备映射补丁（ADR-016），替换 v4 硬编码 | 🟡 已发布源码，**待真机编译验证**（ADR-016 预写 5 条基线） | [`patches/README.md`](../../patches/README.md) |
| **baked-v6 测试镜像** | V5 的另一验证产物 | ⛔ 已裁决不晋升 | `docs/v5-ar2/DELIVERY.md` |

> ⚠️ 官方交流禁裸用 "V5/V6"；指 V5-ar2 时用 **"V5 模块 / ringonly V5 模块"**，指本仓库补丁时用 **"v5-netdev 补丁"**。

## 2. ringonly 补丁完整版本链（服务器实证）

```
Stage A（ring-only 拓扑）
  v1-ring-only            ✅ 2026-08-15 上线
Stage A+（per-peer 设备映射）
  v4-netdev-hardcode      ✅ 2026-08-16 上线（源码内静态表）
Stage B（per-size 协议 tuner）
  stageB-tuner-two-band   ✅ md5 3d9cf539（glibcfix）
  stageB-hardened-two-branch ✅ md5 2be94172（双分支加固，SPCX 劫持防御，生产锚点）
Stage C（V5-ar2 模块，hook 集成）★本次入库
  2026-09-03  S2/S2-W1/W2/W3/WINDOW2 五窗迭代（ar2 引擎原型→引擎定型）
  2026-09-04  v1.0.0 定版（捕获守卫 56028064 → 降级 a1a9f6b1 → fence-arm ac2525a0
              → 审计定版 36c26ab6）+ v1.1.0（含 R3 多 QP 实验）
  2026-09-04  V5 生产镜像晋升（digest 81a0c910；libnccl 4d8ebaaf + libar2 343bea89）
  2026-09-04  R1 图归属细分（164 捕获 op = 77 dspark + 87 目标图）/ R2 Route D 门禁跳过 /
              R3 多 QP 负结果定谳（nqp=1/2/4 无收益，单 QP 已饱和）
  在役形态     R1-diag 镜像 d118ceb2（libnccl 51e36db5 + libar2 343bea89，fence-arm 生效）
后续路线（未开工）
  图内集成（ar2_capture_layer + vLLM 捕获点 patch，把 ≤8KB 人群 9~43% 微基准收益
  搬进 decode 步）——V5-HISTO 直方图已内建，见 docs/v5-ar2/INTEGRATION-ROADMAP.md
```

**关键工程结论（V5-ar2）**：微基准 ≤8KB ar2 领先 9~43%，但生产 decode 通信在 CUDA graph 重放内**不经 hook**、prefill AR 全 >crossover ⇒ **hook 型集成稳态收益 ≈ 0**（结构性定谳，与 ar2 性能无关）。生产价值需走图内集成路线。

## 3. 2-hop 项目完整闭环（服务器实证，补齐归档）

2-hop bilateral **开发完毕并完成终审**：不是「没有做完」，而是 **S1→S2→S3 完整走完后被机制级干净否定**，D 收尾归档（2026-08-17）。

- **S1**：双库搭建 + P0 诊断（垃圾值 [783.875] 根因 = device kernel table 未注册 2HOP，`generate.py` 缺 "2HOP" + `ncclDevFuncId` nAlgos=6 溢出）
- **S2**：proto 库验证（s2-adjudication / readout / QA）
- **S3**：step1 tuner 移植（RING 延迟回 µs 级，lib `d12f3f3f`）→ step2 根因闭环（`d3fc78a4` 2HOP+runRing ok=True）→ 机制级否定（form C `cfa8c14c` / carry `9176e156` 在干净 SIMPLE 下同样 illegal memory access；LL/LL128 价值区编译期隔离不可触及）
- **终审**：`docs/reports/2hop-s3-final-adjudication-2026-08-17.md` —— 技术层面推荐 D 收尾；生产库 `2be94172` 未动

**本次入库的 2hop 增量**（此前 GitHub 缺失）：
- 10 份执行层报告：`docs/2hop-archive-extras/`（step1/2a/2b/诊断结果、P0 诊断、ADR 原件 `nccl-tuner-netdev-hardcode-adr`、production-issues-fix-confirmation 等）
- 补丁脚本三件：`patches/apply_2hop_patch.py`、`record_2a.sh`、`record_2b.sh`
- 自包含 **git-bundle**（4.2MB，可 clone 复现）+ SHA 映射：`archive/2hop-proto/`
- lib md5 血统总表：`archive/2hop-proto/2HOP-LIB-MD5-RECORD.txt`
- S3 门数据 + 失败复现日志：`archive/2hop-proto/s3-gate-data/`、`failure-logs/`

## 4. 生产库指纹现状（与 config/production-nccl-env.md 的关系）

| 库 | md5 | 语义 | 状态 |
|---|---|---|---|
| Stage B hardened | `2be94172` | stageB 终态锚点（ADR-015 语境生产） | 08-16 定版 |
| V5 镜像内 libnccl | `4d8ebaaf` | V5 hook + 捕获静默窗 | 09-04 晋升 |
| R1-diag libnccl | `51e36db5` | fence-arm 在役 | 当前生产 |
| libar2 | `343bea89` | ar2 引擎（四机一致） | 当前生产 |

> 注意：`config/production-nccl-env.md` §3 的生产 md5 描述基于 08-16 快照（2be94172）。V5 晋升后生产语义已迁移至容器内集成形态（同路径替换 + 独立 libar2），详见 `docs/v5-ar2/DELIVERY.md` §5。

## 5. 服务器原始位置索引（取证基准，dgxspark01）

| 内容 | 路径 |
|---|---|
| V5-ar2 交付包（源码/文档/补丁/A-B结果） | `~/sparkring-kit/ringonlyV5/` |
| hardened 源码树（git 0dd44cd）+ SPCX 验证计划 | `~/sparkring-kit/nccl-ringonly-v5/` |
| 源码发布包 1.0.0 / 1.1.0 | `~/sparkring-kit/ringonlyV5-*-src-20260904.tar.gz` |
| V5 生产库（四机一致） | `~/v5libs/` |
| 2-hop 完整归档（D 收尾） | `/opt/aicad-prod/backup/nccl-2hop-proto-archive-20260817/` |
| 2-hop S1 现场库 | dgxspark02 `/opt/2hop-s1/` |

> 脱敏声明：入库文件已做用户名/家目录占位化（`<user>`）；私有 IP 按仓库既有先例保留。
