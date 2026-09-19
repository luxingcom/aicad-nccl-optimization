# 公共 API 参考 — include/ar2.h

14 个函数；C ABI（extern "C"）；线程与生命周期契约见 ERROR-MODEL §6。

---

## 配置与初始化

### `void ar2_config_defaults(ar2_config *cfg)`
填默认值：world=4, ctrl_port=9500, gid_index=3, smax_bytes=65536, nslots=2,
dtype=AR2_DT_BF16, timeout_ms=5000, backend=-1(auto)。
**必调**——调用方应先 defaults 再覆盖；rank/dev0/dev1/peer_ips 必填。

### ar2_config 字段
| 字段 | 约束 | 说明 |
|---|---|---|
| rank, world | world∈{4,2}, 0≤rank<world | world=2 仅 CPU 自测（linkB 自环） |
| peer_ips[4] | peer_ips[0] 必填（rank0 地址）；[1..3] 保留 | rank0 侧忽略；字符串生命周期：**ar2_init 返回后不得释放**（probe 用 static 存储） |
| ctrl_port | ≠0 | TCP 控制面端口（四 rank 同值） |
| dev0, dev1 | 非空且**互异** | verbs 设备名。生产：dev0=rocep1s0f1 (round0), dev1=roceP2p1s0f0 (round1) |
| gid_index | 1..N | 生产=3；注意 0 被视为未设置回退 3 |
| smax_bytes | 64..1MB, 16 对齐 | 槽容量=单 op 最大消息 |
| nslots | 1..8 | 生产=2（槽复用安全性按 2 论证, ARCHITECTURE §7） |
| dtype | CUDA: BF16; CPU: FP32 | 后端能力（ar2_selftest D 组覆盖） |
| timeout_ms | 100..3600000 | engine_wait 层 |
| backend | -1/AR2_BACKEND_CUDA/AR2_BACKEND_CPU | -1 = 按 make_cuda_device 弱符号自动 |

### `int ar2_init(const ar2_config *cfg, ar2_comm **out)`
建连序列：双 arena → 双 QP → TCP 星型 → PeerInfo 全交换+几何校验 → 双 link connect → ready barrier。
成功后 out 可用；失败 out=nullptr，返回错误码（stderr 带 stage 信息；AR2_TRACE=1 显示分步）。
**同步阻塞**：全组一起调，慢节点会拖住全组（连接重试 240×0.5s 上限 → TIMEOUT）。

## 数据面

### `int ar2_allreduce(ar2_comm *w, void *buf, uint32_t bytes)`
M1 单 op：就地 bf16 全和。约束：16≤bytes≤smax_bytes，16B 对齐。
返回 AR2_OK 或错误码（不可恢复错误后 comm 已 poison）。

### `int ar2_allreduce_stream(ar2_comm *w, void *buf, uint32_t bytes, void *cuda_stream)`
NCCL ringonly V5 集成入口：与 ar2_allreduce 相同语义，但 kernel 落在**调用方 CUDA 流**上
（cuda_stream=nullptr 时退回引擎内部流）。输入就绪/输出可见的次序由调用流保证。
**host 阻塞至 op 完成**（返回即可消费）—— 与 NCCL 异步入队契约不同，仅限时延敏感小消息。
NCCL hook（collectives.cc）经 dlopen 以函数指针消费本符号。

### `int ar2_capture_layer(ar2_comm *w, void *const bufs[], const uint32_t bytes[], int n)`
M2：把 n 个 allreduce 固化为一张 CUDA graph（n≤AR2_MAX_LAYER_OPS=64）。
- 仅 CUDA 后端；`AR2_NO_GRAPH=1` 时返回 UNSUPPORTED
- 每个 bufs[i]/bytes[i] 同 ar2_allreduce 约束
- **捕获后缓冲指针必须保持有效且不可移动**（graph 固化指针）；穿插调用 ar2_allreduce 单 op
  **不影响** graph 匹配（graph_matches 只比 bufs/bytes/n），同参 layer 调用仍走 replay

### `int ar2_allreduce_layer(ar2_comm *w, void *const bufs[], const uint32_t bytes[], int n)`
执行一层：参数与捕获匹配 → 单次 graph replay + 逐 op 引擎驱动；不匹配/无 graph → 串行 M1。
**返回语义同 ar2_allreduce**；n 越界返回 INVALID。

## 控制/生命周期

### `int ar2_arm_fence(ar2_comm *w)` — **V5 fence-arm 四 rank 控制面栅栏**：worker 发 'F'、
rank0 在单一共享 deadline (10s) 收齐后回 'G'（收不齐广播 'N' 对称快速失败；worker 等待窗口
= 10s×world 覆盖收集期）。NCCL hook 在 "graph 捕获期之后首个大 AR" 处调用（全 rank 同逻辑
必经 op），到齐放行才开始 ar2 分发 —— 根治 vLLM 启动期 warmup/capture 相位错位错配
（E2E-REPORT §3）。失败返回非 0，调用方应永久放弃武装（全原生，安全方向）。
### `int ar2_init_env(int rank, int world, ar2_comm **out)` — env 驱动构造（NCCL hook 专用）：
AR2_PEERS/AR2_DEV0/AR2_DEV1 必填、AR2_CTRL_PORT 默认 9520（避开探针 9500）。
peer 字符串拷入 .so 静态存储（生命周期=进程）。
### `int ar2_abort(ar2_comm *w, int reason)` — 主动全局中止（级联见 ERROR-MODEL §3）；reason=0 按 ABORTED 处理；幂等。
### `int ar2_finalize(ar2_comm **wp)` — 拆除：sync(5s 上限) → 取证输出(AR2_DUMP=1) → barrier → 释放。wp/null 安全。
### `int ar2_available(void)` — 探测后端：AR2_BACKEND_CUDA / AR2_BACKEND_CPU。
### `int ar2_recommended(uint32_t bytes)` — **V5 路由建议**：bytes ≤ crossover（默认 **8192**，2026-09-04 四机实测定界；env AR2_CROSSOVER_B）→ 1(ar2) 否则 0(NCCL ring)。实际生产分发由 NCCL hook（collectives.cc）执行，本函数是库侧同值路由建议。
### `uint64_t ar2_ops_completed(const ar2_comm *w)` — 已完成 op 计数（RSS/健康监控用）。
### `const char *ar2_strerror(int err)` — 错误码 → 描述。

## 环境变量总表

| 变量 | 默认 | 作用 |
|---|---|---|
| AR2_TIMEOUT_MS | 5000 | engine_wait 超时 |
| AR2_SMAX / AR2_NSLOTS | 65536 / 2 | 配置 0 值时回退 |
| AR2_NO_GRAPH | (未设) | 设置即禁用 M2（判别实验/回退开关） |
| AR2_CROSSOVER_B | 8192 | 路由交叉点（库侧 ar2_recommended 与 NCCL hook 同值；2026-09-04 实测定界） |
| AR2_PEERS / AR2_DEV0 / AR2_DEV1 | — | V5 集成必填（ip 列表 / dev0=rocep1s0f1 / dev1=roceP2p1s0f0） |
| AR2_CTRL_PORT | 9520 | V5 控制面端口（hook 路径） |
| AR2_V5 / AR2_V5_EAGER / AR2_V5_HISTOGRAM | 开 / 关 / 关 | hook 总开关（=0 一键回滚）/ 逃生门（无图负载立即分发）/ 尺寸直方图普查 |
| AR2_DUMP | (未设) | finalize 取证转储 |
| AR2_TRACE | (未设) | init 分步跟踪 |
| (probe 专用) AR2_LAYER_NOPS / AR2_CHECK_EVERY / AR2_NO_MIDCHECK | 8 / 50 / 未设 | 层大小 / 校验周期 / 关周期校验 |
