/* ar2_internal.hpp — 内部结构: 控制字布局 / 链路 / 设备后端接口 / 引擎 */
#ifndef AR2_INTERNAL_HPP
#define AR2_INTERNAL_HPP

#include "ar2.h"
#include <infiniband/verbs.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <string>

#define AR2_DBELL_MAGIC 0xA2C0ULL            /* 门铃高 16 位 */
#define AR2_CROSSOVER_DEFAULT 8192u         /* V5 路由交叉点 (env AR2_CROSSOVER_B) */
#define AR2_MAX_LAYER_OPS 128                /* M2 每 graph 固化上限 (dspark 8tk 实测 87 op, +裕量) */
#define AR2_MAX_GRAPHS 64                    /* M2GI GI-A: 每会话可注册的 vLLM 图层数 (26 descs × 裕量) */
#define AR2_QP_TIMEOUT_S 5
#define AR2_MAX_QPS 4                        /* R3 多 QP 上限 (每链) */
#define AR2_SEQ_FLAG_WORD 16                 /* R3 到达旗标字基: seq 区 word(16+q) = QPq 旗标 (q>=1);
                                              * word0/1 = claim/skew, word2/3 = 金丝雀, 4..15 预留 */

namespace ar2 {

/* ---- 门铃字: [magic16 | flags16 | seq32]; flags bit0 = ABORT ---- */
static inline uint64_t dbell_word(uint32_t seq, uint16_t flags = 0) {
  return (AR2_DBELL_MAGIC << 48) | ((uint64_t)flags << 32) | (uint64_t)seq;
}
static inline bool dbell_magic_ok(uint64_t v) { return (v >> 48) == AR2_DBELL_MAGIC; }
static inline uint32_t dbell_seq(uint64_t v) { return (uint32_t)(v & 0xFFFFFFFFu); }
static inline uint16_t dbell_flags(uint64_t v) { return (uint16_t)((v >> 32) & 0xFFFFu); }

/* ---- 每链控制块 (注册 arena 内, sizeof=56B, 8B 对齐; NIC/host/device 三方可见) ----
 * 排列即偏移契约: dbell=0, producer=8, send_done=16, arm1=24, done=32, abort=40, dev_err=48 */
struct Ar2Ctl {
  volatile uint64_t dbell;      /* 对端 NIC inline WRITE: 门铃字 */
  volatile uint64_t producer;   /* device: x 已 staged 进 send 槽 (seq) */
  volatile uint64_t send_done;  /* host: 门铃 CQE 已收割, 源可复用 (seq) */
  volatile uint64_t arm1;       /* device: round0 已归约进 linkB send 槽 (seq) */
  volatile uint64_t done;       /* device: 最终结果已写回 x (seq) */
  volatile uint64_t abort;      /* host/device: abort 代数 (非 0 = 终止) */
  volatile uint64_t dev_err;    /* device: 错误码 (0 = 无) */
};

/* arena 布局: [recv nslots×smax][send nslots×smax][Ar2Ctl 56B][seq 区 64×8B]
 * seq 区 word0 = device 端原子 claim 计数器 (kernel atomicAdd_system / CPU __atomic_fetch_add),
 * 每 kernel 执行 claim 一个单调 seq —— M2 教训: host 跨 replay 重写映射字存在旧值执行窗口;
 * word1 = 有界偏斜命中计数 (诊断: wait 在对端早到 d==seq+1 时递增, finalize 打印) */
static inline size_t arena_ctl_off(uint32_t smax, int nslots) {
  return (size_t)nslots * smax * 2;
}
static inline size_t arena_bytes(uint32_t smax, int nslots) {
  return arena_ctl_off(smax, nslots) + sizeof(Ar2Ctl) + sizeof(uint64_t) * AR2_MAX_LAYER_OPS;
}

/* ---- 一次 op 的全部指针 (host VA; CUDA 后端在层内换算 device VA) ---- */
struct Ar2OpPtrs {
  volatile Ar2Ctl *ctlA, *ctlB;
  uint8_t *recvA, *sendA;      /* linkA recv/send 区域基址 (不含槽偏移) */
  uint8_t *recvB, *sendB;      /* linkB recv/send 区域基址 */
  volatile uint64_t *seq_ctr;   /* device claim 计数器 (kernel/CPU 后端递增, host 只读) */
  volatile uint64_t *skew_ctr;  /* 偏斜命中计数 (word1; 诊断用) */
  /* R3 到达旗标 (本端 arena 内, 对端 QPq>0 的 inline 签名写落点): flagsA/B = 各自链
   * seq 区 word(AR2_SEQ_FLAG_WORD) 基址, flags[0] 未用 (QP0 旗标即 ctlA/ctlB.dbell)。
   * 消费侧 (kernel wait_flag / CPU 镜像) 仅在 nqp>1 时逐 q>=1 校验, nqp=1 零开销。 */
  volatile uint64_t *flagsA = nullptr, *flagsB = nullptr;
  /* P1 三相到达计数器 (seq 区 word4/5/6: stage/arm1/done; 单调不复位,
   * 目标值由宿主按 3*nblk/op 步进直供 kernel —— 图内 claim 路径不用 (nullptr 检查)) */
  volatile uint64_t *arr_ctr = nullptr;
  uint32_t smax = 0;            /* 槽字节容量 */
  int nslots = 0;
  int nqp = 1;                  /* 每链 RC QP 数 (cfg.nqp, 1=单 QP 原形态) */
};

/* ---- TCP 控制面 (星型: rank0 聚合; 会话期保持, 供 ABORT 中继/拆除 barrier) ---- */
struct CtrlPlane {
  int fds[4] = {-1, -1, -1, -1};   /* fds[r] = 到 rank r 的连接 (自身 = -1) */
  int rank = 0, world = 4;
  /* 8B abort 帧分级缓冲 (审计B2-问题1 修复): recv 可能一次只取到部分字节, 原实现
   * k!=8 即丢弃会永久破坏帧同步。每 fd 粘包直至凑满 8B 再整帧校验。 */
  uint8_t abuf[4][8] = {};
  int alen[4] = {0, 0, 0, 0};
};

/* ---- 一条 RDMA 链路 (proto v6 骨架模块化; R3: 每链 nqp 个 RC QP 共享 PD/CQ/MR) ---- */
struct PeerInfo {
  uint32_t magic, version;
  uint16_t rank, dtype;
  uint32_t smax, nslots;
  uint8_t gid[16];
  uint32_t qpn[AR2_MAX_QPS];       /* 对端每 QP 号 (建连方与本端 QP 一一配对) */
  uint8_t nqp;                     /* 对端 QP 数 (几何校验件: 双方必须一致) */
  uint32_t rkey;
  uint64_t addr;                   /* 对端 arena 基址 */
};
struct Link {
  ibv_context *ctx = nullptr;
  ibv_pd *pd = nullptr;
  ibv_cq *cq = nullptr;
  ibv_qp *qp[AR2_MAX_QPS] = {};   /* qp[0] 兼作 ABORT 门铃通路; 全部共享 cq */
  int nqp = 1;
  ibv_mr *mr = nullptr;
  uint8_t *buf = nullptr;          /* 注册 arena (host VA) */
  size_t buf_bytes = 0;
  PeerInfo peer{};
  uint64_t sent_seq = 0;           /* 诊断遗留: 最后 post 的门铃序号 (当前无消费者, 审计标注) */
  ~Link();
};

/* ---- 设备后端: CUDA(真) / CPU(自测) ---- */
struct Device {
  virtual ~Device() = default;
  virtual const char *name() const = 0;
  virtual void set_timeout(int ms) { (void)ms; }   /* CPU 后端自旋 deadline 用 */
  /* arena: NIC 可注册 + device 可见 (CUDA: cudaHostAllocMapped; CPU: posix) */
  virtual uint8_t *arena_alloc(size_t bytes) = 0;
  virtual void arena_free(uint8_t *p) = 0;
  /* 提交一个 op: CUDA = 在流上 launch fused kernel(自门控); CPU = 记录待执行 */
  virtual int op_submit(void *stream, uint8_t *x, uint32_t bytes, uint64_t seq,
                        uint32_t slot, const Ar2OpPtrs &p) = 0;
  /* CPU 后端: 推进设备侧工作直到里程碑发布 (PRODUCER=0, ARM1=1, DONE=2);
   * CUDA 默认空实现 —— kernel 自驱, host 只自旋标志。 */
  virtual int prepare_milestone(uint8_t *x, uint32_t bytes, uint64_t seq,
                                uint32_t slot, const Ar2OpPtrs &p, int milestone) {
    (void)x; (void)bytes; (void)seq; (void)slot; (void)p; (void)milestone;
    return AR2_OK;
  }
  /* M2 graph (仅 CUDA): 把 n 个 op 固化为一张 graph 并 replay */
  virtual int capture_layer(void *stream, uint8_t *const xs[], const uint32_t bytes[],
                            uint64_t seq_base, volatile uint64_t *seq_words,
                            const Ar2OpPtrs *ptrs, int n) { return AR2_ERR_UNSUPPORTED; }
  virtual int launch_graph(void *stream) { return AR2_ERR_UNSUPPORTED; }
  virtual void sync_stream(void *stream) {}
};

Device *make_cuda_device();   /* ar2_dev_cuda.cu */
Device *make_cpu_device(int dtype);

/* ---- 引擎公共小工具 ---- */
inline void st_release(volatile uint64_t *p, uint64_t v) {
  __atomic_store_n((uint64_t *)p, v, __ATOMIC_RELEASE);
}
inline uint64_t ld_acquire(volatile uint64_t *p) {
  return __atomic_load_n((const uint64_t *)p, __ATOMIC_ACQUIRE);
}
inline void spin_pause() {
#if defined(__aarch64__)
  asm volatile("yield");
#elif defined(__x86_64__)
  asm volatile("pause");
#endif
}
inline int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}
inline int64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace ar2
#endif
