# NCCL 2-hop S3 第一阶段 · SRE 窗口执行报告（Rex）—— 2HOP kernel 阻塞项

**日期**: 2026-08-16
**作者**: Rex（SRE 工程师）
**收件**: team-lead → Archi 裁审 / Tessa 复核
**状态**: 四机窗口已执行；基础设施验证通过（RING G1/G3 全绿）；**2HOP kernel 机制层阻塞**（Archi B/C 均验证不可行，待裁审 A/D）

---

## 0. TL;DR

| 项 | 结果 |
|---|---|
| 测试容器/IB/proto lib 加载 | ✅ 4 机正常（生产镜像 anemll + proto lib LD_PRELOAD） |
| RING 路径正确性（同库） | ✅ G1 4 尺寸全 ok+sum_check；G3 ok=true（修复脚本 bug 后） |
| 2HOP 算法选择/运行 | ✅ 已修复选择+预连接，`NCCL_ALGO=2HOP` 能运行 |
| **2HOP kernel（原设计/B/C）** | ❌ 全部失败（LL 错值 / SIMPLE 死锁）——机制层，非调度 |
| G1/G2/G3 2HOP 数据 | ⛔ 待 Archi 裁审（A 新机制 / D RING 基线） |
| proto lib 状态 | 🔒 安全 ring-fallback（md5 2f21f6b9，不产生错误数据） |

---

## 1. 窗口执行中修复的两个真实 bug

### 1.1 架构缺失：sm_120 → sm_121
- GPU compute capability **12.1**；最初只编译 sm_120 → 内核无法加载 → ncclInternalError。重建 sm_121 后 RING 恢复。

### 1.2 2HOP 预连接缺 case
- `src/group.cc ncclCollPreconnect` 算法 switch 无 2HOP → `default: ncclInternalError`。已加 `case → ncclTransportRingConnect`。

---

## 2. 2HOP kernel 三版实机验证（Archi B/C 均被机制硬阻）

| 版本 | 调度 | SIMPLE | LL/LL128 | 结论 |
|---|---|---|---|---|
| 原实现 | 两步 Primitives 非对称 | 死锁 | 错值 | ❌ |
| direct 原语 | 同上+direct | 死锁 | 错值 | ❌ |
| **Archi B** | 双 Primitive 对称子步 | 死锁 | 错值 | ❌ |
| **Archi C** | pairwise-exchange | 死锁 | 错值 | ❌ |

**关键证据**：三种完全不同的调度在 LL 下输出**完全相同**的垃圾值 `[783.875, 3.015686, ...]` → 问题在**双 Primitives 对象 + direct 原语机制**本身，与调度无关。
- 已排除 group 索引（MaxGroupWidth=2 与 1 均失败）。
- 同库 RING（单 Primitives）完全正确。
- 推断：direct 模式 send 经 RDMA 直写对端 user buffer，in-place 时覆盖本地 reduce 源 → 错值；SIMPLE 下并发直连死锁。现有 ring 原语框架内无法仅靠调度规避。

---

## 3. 附带环境发现（QA 需关注）

- 测试容器（生产镜像）RING allreduce 延迟 **~4.5ms 且各尺寸平坦**（1K-64K）。S2 同环境（sglang 镜像）ring_real@4K=38.6µs。**~100x 异常**，疑似 proto lib 无 tuner 的协议/通道选择或生产镜像差异。
- 该固定开销会**淹没 2-hop 步数收益**（ratio 会贴近 1.0）→ G3 前提在当前环境存疑。

---

## 4. 已交付（RING 基线，option D 部分）

- `s3-g1-ring.json`：G1 {1K,16K,64K,256K} 全 ok=True + sum_check=True。
- `s3-g3-ring-baseline.json`：G3 RING 延迟分布（N=200/尺寸，ok=true）。
- 修复测试脚本 bug：s3_g3_ab.py 迭代间未重置 tensor → 已加 `x.fill_(rank)`。
- proto lib 回退安全 ring-fallback（md5 2f21f6b9），2HOP 入口=ring。

---

## 5. 待 Archi 裁审

1. A（新原语/sendrecv kernel，支持发X收Y，超 Form A-minimal）或 D（RING 基线 + 2HOP INCONCLUSIVE）。
2. 4.5ms 固定开销是否先排查（若真实，2-hop 延迟收益在当前环境无法测出）。

---

## 6. 产物

- proto lib：`/opt/2hop-s1/proto-lib/libnccl.so.2.30.7`（md5 2f21f6b9，安全）
- RING 基线：`/opt/2hop-s1/out-s3/s3-g1-ring.json` + `s3-g3-ring-baseline.json`
- 源码：`/opt/2hop-s1/src/nccl-2hop-proto`（10 commits）
- 失败复现：`/opt/2hop-s1/out-s3/2hop-failures/`
- 生产隔离：md5 2be94172 未变；生产 running=0

*文档更新：2026-08-16（Archi B/C 实机验证完成，机制层阻塞上报）*
