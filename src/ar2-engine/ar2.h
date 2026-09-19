/* ar2.h — S2: GPU 2-round all-exchange allreduce transport (4-rank DGX Spark ring)
 *
 * 线协议: RDMA WRITE(数据) + 8B inline 门铃 [magic16|flags16|seq32], 收端自旋;
 *         round0 peer=rank^1 (linkA), round1 peer=rank^3 (linkB); 每 rank 总线 2S。
 * 目标:   每层矩阵交换总时间最短 (M1 单 kernel/op; M2 整层 graph replay)。
 * 错误:   全等待带 deadline; ABORT 门铃+控制面广播; kernel abort 感知退出。
 * 契约:   返回 AR2_ERR_FATAL_* 后进程必须终止 (stream 可能含未完成依赖),
 *         其余负值可查询 ar2_strerror; 会话被 poison 后全部调用立即失败。
 */
#ifndef AR2_H
#define AR2_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AR2_VERSION 2   /* v2 = R3: PeerInfo 布局变更 (qpn[4]+nqp), 拒绝与 v1 会话混布 */

/* 错误码 (全部 <0) */
enum {
  AR2_OK = 0,
  AR2_ERR_INVALID = -1,     /* 参数/几何非法, 调用前失败 */
  AR2_ERR_NOMEM = -2,
  AR2_ERR_TIMEOUT = -3,     /* 等待超时; 已发起 ABORT; 会话 poison */
  AR2_ERR_ABORTED = -4,     /* 对端/本端 ABORT 传播到 */
  AR2_ERR_PROTOCOL = -5,    /* 门铃 magic/seq 校验失败 */
  AR2_ERR_VERBS = -6,       /* RDMA post/CQE 失败 */
  AR2_ERR_POISONED = -7,    /* 会话已毒化 */
  AR2_ERR_UNSUPPORTED = -8, /* 后端不支持 (如 CPU 后端请求 graph) */
  AR2_ERR_FATAL = -9,       /* 保留码 (当前无产生路径): 入队后不可恢复错误的预留语义;
                                 现行实现中此类失败经 abort 级联安全回收, 返回 VERBS/TIMEOUT */
  AR2_ERR_REMOTE = -10,     /* 对端报错经门铃/控制面传来 */
  AR2_ERR_CUDA = -11,
};

/* 数据类型 */
enum { AR2_DT_BF16 = 0, AR2_DT_FP32 = 1 };

/* 后端 */
enum { AR2_BACKEND_CPU = 0, AR2_BACKEND_CUDA = 1 };

typedef struct ar2_comm ar2_comm;

typedef struct {
  int rank, world;               /* world = 4 生产; = 2 自环自测 */
  const char *peer_ips[4];       /* 控制面 IP, 按逻辑 rank; 自身槽位可 NULL */
  int ctrl_port;                 /* rank0 监听端口 (其余 rank 连它), 默认 9500 */
  const char *dev0, *dev1;       /* linkA(rank^1) / linkB(rank^3 或自环) 设备名 */
  int gid_index;                 /* 两链一致, 默认 3; 注意 0 被视为未设置回退 3 (审计标注) */
  uint32_t smax_bytes;           /* 单 op 上限, 默认 65536; 须 16 对齐 */
  int nslots;                    /* 槽位数, 默认 2 (串行深度 1) */
  int nqp;                       /* R3 每链 RC QP 数 (1..4), 默认 0 = env AR2_QPS 回退, 最终 1;
                                  * >1 时 bulk 条带到多 QP 并行, 尾旗标落 seq 区 word(16+q) */
  int dtype;                     /* AR2_DT_BF16 (CUDA v0.1 仅 bf16) / AR2_DT_FP32 */
  int timeout_ms;                /* 全部等待 deadline, 默认 5000 */
  int backend;                   /* AR2_BACKEND_CUDA / AR2_BACKEND_CPU */
} ar2_config;

/* 静态默认值填充 (纯填充, 不读环境; timeout_ms/smax_bytes/nslots/nqp 填 0 = 未设哨兵,
 * env 回退在 ar2_init 对 0 值字段进行: AR2_TIMEOUT_MS / AR2_SMAX / AR2_NSLOTS / AR2_QPS
 * → 5000 / 65536 / 2 / 1。审计修正: AR2_BACKEND 无 env 通路) */
void ar2_config_defaults(ar2_config *cfg);

int ar2_init(const ar2_config *cfg, ar2_comm **out);

/* 就地 allreduce: buf[i] = Σ_rank buf[i]。backend=CUDA 时 buf 为设备指针。
 * bytes ≤ smax_bytes 且 16 对齐。M1: 每 op 1 fused kernel + 2×nqp WR burst。 */
int ar2_allreduce(ar2_comm *c, void *buf, uint32_t bytes);

/* NCCL ringonly V5 集成入口: 在调用方的 CUDA 流上执行单 op (M1)。
 * kernel 与调用流同序 ⇒ 输入就绪/输出可见次序由流保证 (engine 仍 host 阻塞至完成)。
 * cuda_stream = nullptr 时等同 ar2_allreduce (内部流)。
 * 注意: host 阻塞语义与 NCCL 异步入队契约不同 —— 仅适用于时延敏感的关键路径小消息。 */
int ar2_allreduce_stream(ar2_comm *c, void *buf, uint32_t bytes, void *cuda_stream);

/* V5 fence-arm 栅栏: 四 rank 控制面集合点 (worker 发 'F', rank0 收齐回 'G', 10s)。
 * NCCL hook 在 "graph 捕获期之后首个大 AR" 处调用 —— 全 rank 同逻辑触发点, 到齐放行
 * 才开始 ar2 分发, 根治 vLLM 启动期 warmup/capture 相位错位的错配。失败=放弃武装。 */
int ar2_arm_fence(ar2_comm *c);

/* M2: 把 n 个 (bufs, bytes) 固化进一张 CUDA graph (仅 CUDA 后端)。
 * 之后 ar2_allreduce_layer 同参调用走 replay: 1 graphLaunch + n×2 WR burst。 */
int ar2_capture_layer(ar2_comm *c, void *const bufs[], const uint32_t bytes[], int n);
int ar2_allreduce_layer(ar2_comm *c, void *const bufs[], const uint32_t bytes[], int n);

/* M2GI GI-A (vLLM 图内集成, 2026-09-04): kernel 录进调用方自己的 FULL 图。
 * ar2_capture_op_stream: 捕获期在指定流上录单 op kernel (不执行 host 协议)。
 * ar2_layer_register: 捕获结束注册层表 (bufs 须 16 对齐图池静态地址)。
 * ar2_layer_drive: 重放期 launch 调用方图后立即调用 —— host 五拍 WR 驱动。
 * 约束: 单流程序序重放 + drive 紧随 launch; 不与 m1/hook 路径混用同一会话。 */
int ar2_capture_op_stream(ar2_comm *c, void *buf, uint32_t bytes, void *cuda_stream);
int ar2_layer_register(ar2_comm *c, uint32_t *gid, void *const bufs[], const uint32_t bytes[], int n);
int ar2_layer_drive(ar2_comm *c, uint32_t gid);

/* 主动终止: 置本地 abort + 双链 ABORT 门铃 + 控制面广播。幂等, 不抛出。 */
int ar2_abort(ar2_comm *c, int reason);

/* 幂等拆除: sync stream(若 CUDA) → 控制面 barrier(尽力) → QP/CQ/MR/PD → arena 还后端 → fd。
 * 须在数据面静止 (所有调用线程已返回) 后调用 (审计标注: 并发数据面调用下无保护)。 */
int ar2_finalize(ar2_comm **c);

/* V5 路由钩子 */
int ar2_available(void);               /* 编译期后端可用性 */
int ar2_recommended(uint32_t bytes);   /* 1=ar2 (≤ AR2_CROSSOVER_B, 默认 8192B 实测定界), 0=ring */

/* NCCL ringonly V5 集成件: env 驱动构造 (NCCL 侧 dlopen 后仅见此符号 + ar2_allreduce_stream)。
 * env: AR2_PEERS=ip0,ip1,ip2,ip3 (必填) / AR2_DEV0 / AR2_DEV1 (必填, 无默认; 生产值
 *      dev0=rocep1s0f1 / dev1=roceP2p1s0f0) /
 *      AR2_CTRL_PORT (默认 9520, 避开探针 9500) / AR2_QPS (默认 1; R3 每链 QP 数 1..4)。
 * peer 字符串拷入 .so 内静态存储 (生命周期=进程, 规避 API.md 悬挂指针契约)。 */
int ar2_init_env(int rank, int world, ar2_comm **out);

const char *ar2_strerror(int err);

/* 统计 (调试): 返回本会话完成的 op 数 */
uint64_t ar2_ops_completed(const ar2_comm *c);

#ifdef __cplusplus
}
#endif
#endif
