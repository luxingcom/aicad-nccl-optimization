/* ar2_dev_cuda.cu — CUDA 后端: mapped arena + 单 fused kernel/op (abort 感知) + 整层 graph */
#include "ar2_internal.hpp"

#include <cuda_bf16.h>
#include <cuda_runtime.h>

#include <cstdio>
#include <cstring>
#include <vector>

namespace ar2 {
namespace {

/* ---- device 侧发布/等待 (SparkRing 范式: threadfence_system + volatile; 强化二: abort 退出) ---- */
__device__ __forceinline__ void dev_pub(volatile uint64_t *p, uint64_t v) {
  __threadfence_system();
  *p = v;
}

/* 有界偏斜容忍: 对端最多领先本端 1 op (其 m+2 需要本端 m+1 完成才能发出, 槽数学保证
 * seq 数据在领先 1 op 时仍完好)。d==seq+1 视为合法早到 (SparkRing eager 先例);
 * d>seq+1 = 真错账。seq 区 word[1] = 偏斜命中计数 (诊断)。 */
__device__ int wait_two(volatile Ar2Ctl *L, uint64_t seq, volatile unsigned long long *skew_ctr) {
  for (;;) {
    uint64_t d = L->dbell;
    if (d != 0) {   /* 0 = 未到达, 非错误 */
      if ((d >> 48) != AR2_DBELL_MAGIC) return AR2_ERR_PROTOCOL;
      if ((d >> 32) & 1) return AR2_ERR_ABORTED;
      uint32_t ds = (uint32_t)d;
      uint32_t diff = ds - (uint32_t)seq;   /* 模 2^32 差, 防 seq 低 32 位回绕误判 (审计修复 v2:
                                             * 初版把"门铃已到但 send_done 未就绪"(diff==0 且
                                             * send_done<seq) 的正常自旋态误判为错账 — GPU 并发
                                             * 轮询才触发, CPU 镜像自测不可见) */
      if (diff == 0xFFFFFFFFu) {
        /* 落后 1: 未到达, 继续自旋 */
      } else if (diff <= 1) {
        if (L->send_done >= seq) {
          if (diff == 1 && skew_ctr) atomicAdd_system((unsigned long long *)skew_ctr, 1ULL);
          return AR2_OK;
        }
        /* 门铃已到但本端 send_done 未就绪: 继续自旋 (禁止在此报错!) */
      } else {
        return AR2_ERR_PROTOCOL;   /* 超前 >1 = 真错账 */
      }
    }
    if (L->abort) return AR2_ERR_ABORTED;
    __nanosleep(64);
  }
}

/* R3 到达旗标 (QPq>0 的 inline 签名写, 本端 seq 区 word(16+q)): 与 dbell 同字格式、
 * 同模 2^32 差容忍。无独立 send_done 门槛 —— RC 队列内有序放置保证旗标到达即本 QP
 * 数据段已落槽 (与门铃的 bulk→doorbell 推理同源); 有界偏斜 (diff==1) 沿用槽数学。
 * abort 观测走所属链 ctl.abort (host abort_path 经 QP0 发 ABORT 门铃 + 本地字)。 */
__device__ int wait_flag(volatile Ar2Ctl *L, volatile unsigned long long *flag, uint64_t seq) {
  for (;;) {
    uint64_t d = *flag;
    if (d != 0) {
      if ((d >> 48) != AR2_DBELL_MAGIC) return AR2_ERR_PROTOCOL;
      if ((d >> 32) & 1) return AR2_ERR_ABORTED;
      uint32_t diff = (uint32_t)d - (uint32_t)seq;
      if (diff == 0xFFFFFFFFu) {
        /* 未到达, 继续自旋 */
      } else if (diff <= 1) {
        return AR2_OK;   /* seq 或 seq+1 (对端领先 1 op, 槽数学保证本 op 数据完好) */
      } else {
        return AR2_ERR_PROTOCOL;
      }
    }
    if (L->abort) return AR2_ERR_ABORTED;
    __nanosleep(64);
  }
}

/* M2 根因修复: 槽数据走 __stwt/__ldcv 缓存序内在函数。
 * graph replay 下 staging 对 host 映射槽的普通写会滞留 GPU L2 (write-back 延迟),
 * CPU 快照与 NIC DMA 都读到 DRAM 旧值 → 整代数据滞后; recv 槽反向同理 (L2 旧行)。
 * __stwt = write-through 直达系统内存; __ldcv = 绕 L2 的易变读。 */
__device__ __forceinline__ void bf16_copy(__nv_bfloat16 *dst, const __nv_bfloat16 *src,
                                          uint32_t elems, uint32_t base, uint32_t stride) {
  /* P1 向量化: 16B (8×bf16) __stwt —— 2B 逐元素写放大是 stage 7.3GB/s 的主因 */
  uint32_t n8 = elems >> 3;
  const uint4 *s4 = (const uint4 *)src;
  uint4 *d4 = (uint4 *)dst;
  for (uint32_t i = base; i < n8; i += stride) __stwt(d4 + i, s4[i]);
  for (uint32_t i = (n8 << 3) + base; i < elems; i += stride) __stwt(dst + i, src[i]);
}
/* sB = sA + rA: 双侧输入均为 host 映射槽 (a=send 本端 staged, b=recv 对端 NIC DMA 写入),
 * 输出 sB 也是 NIC 待 DMA 的槽 → 全程 __ldcv/__stwt */
__device__ __forceinline__ void bf16_add_wt(__nv_bfloat16 *dst, const __nv_bfloat16 *a,
                                            const __nv_bfloat16 *b, uint32_t elems,
                                            uint32_t base, uint32_t stride) {
  uint32_t n8 = elems >> 3;
  const uint4 *a4 = (const uint4 *)a;
  const uint4 *b4 = (const uint4 *)b;
  uint4 *d4 = (uint4 *)dst;
  for (uint32_t i = base; i < n8; i += stride) {
    uint4 va = __ldcv(a4 + i), vb = __ldcv(b4 + i);
    __nv_bfloat162 r0 = __hadd2(*(const __nv_bfloat162 *)&va.x, *(const __nv_bfloat162 *)&vb.x);
    __nv_bfloat162 r1 = __hadd2(*(const __nv_bfloat162 *)&va.y, *(const __nv_bfloat162 *)&vb.y);
    __nv_bfloat162 r2 = __hadd2(*(const __nv_bfloat162 *)&va.z, *(const __nv_bfloat162 *)&vb.z);
    __nv_bfloat162 r3 = __hadd2(*(const __nv_bfloat162 *)&va.w, *(const __nv_bfloat162 *)&vb.w);
    uint4 out = {*(const unsigned *)&r0, *(const unsigned *)&r1,
                 *(const unsigned *)&r2, *(const unsigned *)&r3};
    __stwt(d4 + i, out);
  }
  uint32_t n2 = elems >> 1;
  __nv_bfloat162 *d2 = (__nv_bfloat162 *)dst;
  const __nv_bfloat162 *a2 = (const __nv_bfloat162 *)a;
  const __nv_bfloat162 *b2 = (const __nv_bfloat162 *)b;
  for (uint32_t i = (n8 << 2) + (base >> 1); i < n2; i += stride)   /* 16B 之外的 bf162 残段 */
    __stwt(d2 + i, __hadd2(__ldcv(a2 + i), __ldcv(b2 + i)));
  if ((elems & 1) && base == 0)   /* 尾元素: 全局 0 号线程 */
    __stwt(dst + elems - 1, __hadd(__ldcv(a + elems - 1), __ldcv(b + elems - 1)));
}
/* x = sB + rB: 输入是 host 映射槽 (__ldcv), 输出 x 是设备内存 (普通写) */
__device__ __forceinline__ void bf16_add_final(__nv_bfloat16 *dst, const __nv_bfloat16 *a,
                                               const __nv_bfloat16 *b, uint32_t elems,
                                               uint32_t base, uint32_t stride) {
  uint32_t n8 = elems >> 3;
  const uint4 *a4 = (const uint4 *)a;
  const uint4 *b4 = (const uint4 *)b;
  uint4 *d4 = (uint4 *)dst;
  for (uint32_t i = base; i < n8; i += stride) {
    uint4 va = __ldcv(a4 + i), vb = __ldcv(b4 + i);
    __nv_bfloat162 r0 = __hadd2(*(const __nv_bfloat162 *)&va.x, *(const __nv_bfloat162 *)&vb.x);
    __nv_bfloat162 r1 = __hadd2(*(const __nv_bfloat162 *)&va.y, *(const __nv_bfloat162 *)&vb.y);
    __nv_bfloat162 r2 = __hadd2(*(const __nv_bfloat162 *)&va.z, *(const __nv_bfloat162 *)&vb.z);
    __nv_bfloat162 r3 = __hadd2(*(const __nv_bfloat162 *)&va.w, *(const __nv_bfloat162 *)&vb.w);
    d4[i] = {*(const unsigned *)&r0, *(const unsigned *)&r1,
             *(const unsigned *)&r2, *(const unsigned *)&r3};
  }
  uint32_t n2 = elems >> 1;
  __nv_bfloat162 *d2 = (__nv_bfloat162 *)dst;
  const __nv_bfloat162 *a2 = (const __nv_bfloat162 *)a;
  const __nv_bfloat162 *b2 = (const __nv_bfloat162 *)b;
  for (uint32_t i = (n8 << 2) + (base >> 1); i < n2; i += stride)
    d2[i] = __hadd2(__ldcv(a2 + i), __ldcv(b2 + i));
  if ((elems & 1) && base == 0)
    dst[elems - 1] = __hadd(__ldcv(a + elems - 1), __ldcv(b + elems - 1));
}

/* 单 block fused kernel: stage → R0 交换+归约 → R1 交换+最终归约回 x (就地)。
 * 槽基址由 ctl 反推: arena = [recv nslots×smax][send nslots×smax][ctl]。
 * seq 由 device 端原子 claim (graph replay 安全: 每 kernel 执行 claim 单调递增)。
 * R3: nqp>1 时每轮 wait_two 后补等各 QP 旗标 (flags 基址 = 各链 seq 区 word16)。 */
__global__ void ar2_fused_kernel(volatile Ar2Ctl *A, volatile Ar2Ctl *B, __nv_bfloat16 *x,
                                 uint32_t elems, uint32_t stride_elems, uint32_t nslots,
                                 volatile unsigned long long *seq_ctr,
                                 volatile unsigned long long *skew_ctr,
                                 volatile unsigned long long *dbg,
                                 volatile unsigned long long *flagsA,
                                 volatile unsigned long long *flagsB, int nqp) {
  __shared__ uint64_t seq_sh;
  __shared__ int err_sh;
  if (threadIdx.x == 0) {
    seq_sh = (uint64_t)atomicAdd_system((unsigned long long *)seq_ctr, 1ULL) + 1;
    err_sh = 0;
  }
  __syncthreads();
  const uint64_t seq = seq_sh;
  const uint32_t slot = (uint32_t)((seq - 1) % nslots);
  const size_t zone = (size_t)nslots * stride_elems * 2;   /* send 区字节数 */
  __nv_bfloat16 *sendA = (__nv_bfloat16 *)((uint8_t *)A - zone);
  const __nv_bfloat16 *recvA = (const __nv_bfloat16 *)((uint8_t *)A - zone * 2);
  __nv_bfloat16 *sendB = (__nv_bfloat16 *)((uint8_t *)B - zone);
  const __nv_bfloat16 *recvB = (const __nv_bfloat16 *)((uint8_t *)B - zone * 2);
  __nv_bfloat16 *sA = sendA + (size_t)slot * stride_elems;
  const __nv_bfloat16 *rA = recvA + (size_t)slot * stride_elems;
  __nv_bfloat16 *sB = sendB + (size_t)slot * stride_elems;
  const __nv_bfloat16 *rB = recvB + (size_t)slot * stride_elems;

  bf16_copy(sA, x, elems, threadIdx.x, blockDim.x);   /* stage (__stwt 直达系统内存) */
  __syncthreads();   /* 审计 F1 修复: 全 block 写完才发布 (threadfence_system 只序本线程写) */
  if (threadIdx.x == 0) {   /* 金丝雀: kernel 实际读到的 x / 写出的 sA 首元素 (16b) */
    dbg[0] = ((uint64_t)seq << 32) | *(const unsigned short *)x;
    dbg[1] = ((uint64_t)seq << 32) | *(const unsigned short *)sA;
    dev_pub(&A->producer, seq);   /* dev_pub 内 fence; 经 syncthreads 覆盖全 block 写 */
  }
  __syncthreads();
  if (threadIdx.x == 0) err_sh = wait_two(A, seq, skew_ctr);
  __syncthreads();
  if (!err_sh && threadIdx.x == 0 && nqp > 1) {   /* R3: QP1..nqp-1 旗标逐个补等 (仅 0 线程自旋) */
    for (int q = 1; q < nqp && !err_sh; q++) err_sh = wait_flag(A, flagsA + q, seq);
  }
  __syncthreads();
  if (err_sh) {
    if (threadIdx.x == 0) A->dev_err = ((uint64_t)err_sh & 0xFF) | ((uint64_t)(uint32_t)seq << 8);
    return;
  }
  bf16_add_wt(sB, sA, rA, elems, threadIdx.x, blockDim.x);   /* sB = sA + rA (__ldcv 读 recv 槽) */
  __syncthreads();   /* F1: 发布前先聚合全 block 写 */
  if (threadIdx.x == 0) dev_pub(&B->arm1, seq);
  __syncthreads();
  if (threadIdx.x == 0) err_sh = wait_two(B, seq, skew_ctr);
  __syncthreads();
  if (!err_sh && threadIdx.x == 0 && nqp > 1) {
    for (int q = 1; q < nqp && !err_sh; q++) err_sh = wait_flag(B, flagsB + q, seq);
  }
  __syncthreads();
  if (err_sh) {
    if (threadIdx.x == 0) B->dev_err = ((uint64_t)err_sh & 0xFF) | ((uint64_t)(uint32_t)seq << 8);
    return;
  }
  bf16_add_final(x, sB, rB, elems, threadIdx.x, blockDim.x);   /* x = sB + rB (就地终值, 设備内存普通写) */
  __syncthreads();   /* F1: done=seq 必须蕴含 x 全量写完 (调用方见 done 即读 x) */
  if (threadIdx.x == 0) dev_pub(&B->done, seq);
}

/* P1 多 block 变体: 单 block 256 线程的顺序 volatile 相干访存是实测 ~4GB/s 主瓶颈
 * (256KB op: prod/arm1/done 三拍 323µs/380µs)。本变体按尺寸开多 block 并行分片,
 * 跨 block 同步用【三相到达计数器 + 末到者发布】(word4/5/6, 单调不复位):
 *   数据写(__stwt) → threadfence_system → atomicAdd_system(到达) → 末到者 fence+发布
 * —— 无自旋屏障, 无死锁面; block 间对 dbell 的等待各自独立 (RC 有序放置语义下安全)。
 * seq/slot/到达目标由宿主直供 (direct/m1 路径 host 已知 seq); 图内 claim 路径
 * (capture 后重放) 仍走原单 block kernel —— 两条路径互不干扰, arr 计数器仅本变体使用。 */
__global__ void ar2_fused_kernel_mb(volatile Ar2Ctl *A, volatile Ar2Ctl *B, __nv_bfloat16 *x,
                                    uint32_t elems, uint32_t stride_elems, uint32_t nslots,
                                    volatile unsigned long long *skew_ctr,
                                    volatile unsigned long long *dbg,
                                    volatile unsigned long long *flagsA,
                                    volatile unsigned long long *flagsB, int nqp,
                                    uint64_t seq, uint32_t slot,
                                    volatile unsigned long long *arr,
                                    unsigned long long tgt_s, unsigned long long tgt_a,
                                    unsigned long long tgt_f) {
  const uint32_t gsz = gridDim.x * blockDim.x;
  const uint32_t gbase = blockIdx.x * blockDim.x + threadIdx.x;
  const size_t zone = (size_t)nslots * stride_elems * 2;
  __nv_bfloat16 *sendA = (__nv_bfloat16 *)((uint8_t *)A - zone);
  const __nv_bfloat16 *recvA = (const __nv_bfloat16 *)((uint8_t *)A - zone * 2);
  __nv_bfloat16 *sendB = (__nv_bfloat16 *)((uint8_t *)B - zone);
  const __nv_bfloat16 *recvB = (const __nv_bfloat16 *)((uint8_t *)B - zone * 2);
  __nv_bfloat16 *sA = sendA + (size_t)slot * stride_elems;
  const __nv_bfloat16 *rA = recvA + (size_t)slot * stride_elems;
  __nv_bfloat16 *sB = sendB + (size_t)slot * stride_elems;
  const __nv_bfloat16 *rB = recvB + (size_t)slot * stride_elems;

  bf16_copy(sA, x, elems, gbase, gsz);              /* stage 分片 */
  __syncthreads();
  if (threadIdx.x == 0) {
    __threadfence_system();                          /* 本 block 分片写入先行 */
    if (atomicAdd_system((unsigned long long *)arr, 1ULL) + 1 == tgt_s) {
      if (blockIdx.x == 0) {                         /* 金丝雀仅 block0 写 (与单 block 版同位) */
        dbg[0] = ((uint64_t)seq << 32) | *(const unsigned short *)x;
        dbg[1] = ((uint64_t)seq << 32) | *(const unsigned short *)sA;
      }
      dev_pub(&A->producer, seq);                    /* 末到者发布 */
    }
  }
  __syncthreads();
  int err_sh = 0;
  if (threadIdx.x == 0) err_sh = wait_two(A, seq, skew_ctr);
  __syncthreads();
  if (!err_sh && threadIdx.x == 0 && nqp > 1) {
    for (int q = 1; q < nqp && !err_sh; q++) err_sh = wait_flag(A, flagsA + q, seq);
  }
  __syncthreads();
  if (err_sh) {
    if (threadIdx.x == 0) A->dev_err = ((uint64_t)err_sh & 0xFF) | ((uint64_t)(uint32_t)seq << 8);
    return;
  }
  bf16_add_wt(sB, sA, rA, elems, gbase, gsz);        /* sB = sA + rA 分片 */
  __syncthreads();
  if (threadIdx.x == 0) {
    __threadfence_system();
    if (atomicAdd_system((unsigned long long *)(arr + 1), 1ULL) + 1 == tgt_a)
      dev_pub(&B->arm1, seq);
  }
  __syncthreads();
  if (threadIdx.x == 0) err_sh = wait_two(B, seq, skew_ctr);
  __syncthreads();
  if (!err_sh && threadIdx.x == 0 && nqp > 1) {
    for (int q = 1; q < nqp && !err_sh; q++) err_sh = wait_flag(B, flagsB + q, seq);
  }
  __syncthreads();
  if (err_sh) {
    if (threadIdx.x == 0) B->dev_err = ((uint64_t)err_sh & 0xFF) | ((uint64_t)(uint32_t)seq << 8);
    return;
  }
  bf16_add_final(x, sB, rB, elems, gbase, gsz);      /* x = sB + rB 分片 */
  __syncthreads();
  if (threadIdx.x == 0) {
    __threadfence_system();
    if (atomicAdd_system((unsigned long long *)(arr + 2), 1ULL) + 1 == tgt_f)
      dev_pub(&B->done, seq);
  }
}

struct ArenaMap {
  uint8_t *host, *dev;
  size_t bytes;
};

struct CudaDevice final : Device {
  cudaStream_t stream = nullptr;
  cudaGraphExec_t gexec = nullptr;
  std::vector<ArenaMap> arenas;
  /* P1 多 block 几何: 到达计数器累计基 (宿主单线程引擎假设下单调; 图内 claim 路径
   * 不走本变体不推进)。nblk 策略: ≤16KB 单 block (原路径零回归), 之上按 8KB/block
   * 线性到 48 (SM 数, 保证全 block 共驻留 —— 到达计数无屏障无死锁, 共驻留非必需,
   * 但避免尾 block 迟调度拉长末到者等待)。AR2_NBLK env 可钉死 (1=强制原路径)。 */
  unsigned long long arr_total = 0;
  int nblk_env = -1;
  CudaDevice() : nblk_env(getenv_int("AR2_NBLK")) { cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking); }
  static int getenv_int(const char *k) {
    const char *v = getenv(k);
    return (v && *v) ? atoi(v) : -1;
  }
  uint32_t nblk_for(uint32_t bytes) const {
    if (nblk_env >= 1) return (uint32_t)nblk_env;
    if (bytes <= 16384) return 1;
    uint32_t n = (bytes + 8191) / 8192;
    return n > 48 ? 48 : n;
  }
  ~CudaDevice() override {
    if (gexec) cudaGraphExecDestroy(gexec);
    if (stream) cudaStreamDestroy(stream);
    for (auto &m : arenas) cudaFreeHost(m.host);
  }
  const char *name() const override { return "cuda"; }

  uint8_t *arena_alloc(size_t bytes) override {
    void *p = nullptr;
    cudaError_t ae = cudaHostAlloc(&p, bytes, cudaHostAllocMapped);
    if (ae != cudaSuccess) {   /* 真错误码落地 (M2GI 窗口实锤: NOMEM 伞掩了真因) */
      fprintf(stderr, "[ar2] cudaHostAlloc(%zu) fail: %s\n", bytes, cudaGetErrorString(ae));
      return nullptr;
    }
    void *d = nullptr;
    if (cudaHostGetDevicePointer(&d, p, 0) != cudaSuccess) {
      cudaFreeHost(p);
      return nullptr;
    }
    memset(p, 0, bytes);
    arenas.push_back({(uint8_t *)p, (uint8_t *)d, bytes});
    return (uint8_t *)p;
  }
  void arena_free(uint8_t *p) override {
    for (size_t i = 0; i < arenas.size(); i++)
      if (arenas[i].host == p) {
        cudaFreeHost(p);
        arenas.erase(arenas.begin() + (long)i);
        return;
      }
  }
  uint8_t *dev_of(uint8_t *host, size_t len) {
    for (auto &m : arenas)
      if (host >= m.host && host + len <= m.host + m.bytes) return m.dev + (host - m.host);
    return nullptr;
  }

  int launch_one(uint8_t *x, uint32_t bytes, const Ar2OpPtrs &p, cudaStream_t s) {
    uint8_t *dCtlA = dev_of((uint8_t *)p.ctlA, sizeof(Ar2Ctl));
    uint8_t *dCtlB = dev_of((uint8_t *)p.ctlB, sizeof(Ar2Ctl));
    uint8_t *dSeq = dev_of((uint8_t *)p.seq_ctr, 8);
    uint8_t *dSkew = dev_of((uint8_t *)p.skew_ctr, 8);
    uint8_t *dDbg = dSeq ? dSeq + 16 : nullptr;   /* seq 区 word2/3 = 金丝雀 */
    uint8_t *dFlagsA = dSeq ? dSeq + AR2_SEQ_FLAG_WORD * 8 : nullptr;   /* word16 起 = R3 旗标 */
    uint8_t *dFlagsB = p.flagsB ? dev_of((uint8_t *)p.flagsB, 8) : nullptr;
    int nqp = p.nqp > 0 ? p.nqp : 1;
    if (!dCtlA || !dCtlB || !dSeq || !dSkew || !p.smax || !p.nslots) return AR2_ERR_INVALID;
    if (nqp > 1 && (!dFlagsA || !dFlagsB)) return AR2_ERR_INVALID;   /* 条带模式缺旗标映射 = 配置错 */
    ar2_fused_kernel<<<1, 256, 0, s>>>((volatile Ar2Ctl *)dCtlA, (volatile Ar2Ctl *)dCtlB,
                                       (__nv_bfloat16 *)x, bytes / 2, p.smax / 2,
                                       (uint32_t)p.nslots, (volatile unsigned long long *)dSeq,
                                       (volatile unsigned long long *)dSkew,
                                       (volatile unsigned long long *)dDbg,
                                       (volatile unsigned long long *)dFlagsA,
                                       (volatile unsigned long long *)dFlagsB, nqp);
    cudaError_t le = cudaGetLastError();
    if (le != cudaSuccess)
      fprintf(stderr, "[ar2] kernel launch fail: %s (nqp=%d bytes=%u)\n", cudaGetErrorString(le), nqp, bytes);
    return le == cudaSuccess ? AR2_OK : AR2_ERR_CUDA;
  }

  int launch_multi(uint8_t *x, uint32_t bytes, uint64_t seq, uint32_t slot,
                   const Ar2OpPtrs &p, uint32_t nblk, cudaStream_t s) {
    uint8_t *dCtlA = dev_of((uint8_t *)p.ctlA, sizeof(Ar2Ctl));
    uint8_t *dCtlB = dev_of((uint8_t *)p.ctlB, sizeof(Ar2Ctl));
    uint8_t *dSeq = dev_of((uint8_t *)p.seq_ctr, 8);
    uint8_t *dSkew = dev_of((uint8_t *)p.skew_ctr, 8);
    uint8_t *dDbg = dSeq ? dSeq + 16 : nullptr;
    uint8_t *dFlagsA = dSeq ? dSeq + AR2_SEQ_FLAG_WORD * 8 : nullptr;
    uint8_t *dFlagsB = p.flagsB ? dev_of((uint8_t *)p.flagsB, 8) : nullptr;
    uint8_t *dArr = dev_of((uint8_t *)p.arr_ctr, 24);   /* word4/5/6 三相计数器 */
    int nqp = p.nqp > 0 ? p.nqp : 1;
    if (!dCtlA || !dCtlB || !dSeq || !dSkew || !dDbg || !dArr || !p.smax || !p.nslots)
      return AR2_ERR_INVALID;
    if (nqp > 1 && (!dFlagsA || !dFlagsB)) return AR2_ERR_INVALID;
    /* 三相计数器为独立字: 每相各自计满 nblk, 目标同值 = base+nblk; base 按 op 步进 nblk */
    unsigned long long ts = arr_total + nblk;
    unsigned long long ta = ts, tf = ts;
    arr_total += nblk;
    ar2_fused_kernel_mb<<<nblk, 256, 0, s>>>(
        (volatile Ar2Ctl *)dCtlA, (volatile Ar2Ctl *)dCtlB, (__nv_bfloat16 *)x,
        bytes / 2, p.smax / 2, (uint32_t)p.nslots, (volatile unsigned long long *)dSkew,
        (volatile unsigned long long *)dDbg, (volatile unsigned long long *)dFlagsA,
        (volatile unsigned long long *)dFlagsB, nqp, seq, slot,
        (volatile unsigned long long *)dArr, ts, ta, tf);
    cudaError_t le = cudaGetLastError();
    if (le != cudaSuccess)
      fprintf(stderr, "[ar2] mb kernel launch fail: %s (nblk=%u bytes=%u)\n",
              cudaGetErrorString(le), nblk, bytes);
    return le == cudaSuccess ? AR2_OK : AR2_ERR_CUDA;
  }

  int op_submit(void *s, uint8_t *x, uint32_t bytes, uint64_t seq, uint32_t slot,
                const Ar2OpPtrs &p) override {
    /* 调用方流优先 (M2GI 图内录制硬前提; m1 ext_stream 契约同步生效):
     * 原实现丢弃流参数恒落内部流 —— m1 因 host 阻塞不可见, 图捕获直接致命 */
    cudaStream_t st = s ? (cudaStream_t)s : stream;
    uint32_t nblk = p.arr_ctr ? nblk_for(bytes) : 1;   /* 图内/无计数器 = 原路径 */
    if (nblk <= 1) return launch_one(x, bytes, p, st);
    return launch_multi(x, bytes, seq, slot, p, nblk, st);
  }

  int capture_layer(void *, uint8_t *const xs[], const uint32_t bytes[], uint64_t,
                    volatile uint64_t *seq_ctr, const Ar2OpPtrs *p, int n) override {
    /* 先毁旧 gexec: 重捕获即旧执行体失效 —— 旧图内嵌上次捕获时的 kernel 节点/参数,
     * 保留会让下一次 launch_graph 仍重放旧 op 序列 (与 ar2_core graph.valid 审计修复联动) */
    if (gexec) {
      cudaGraphExecDestroy(gexec);
      gexec = nullptr;
    }
    if (!dev_of((uint8_t *)seq_ctr, 8)) return AR2_ERR_INVALID;
    cudaGraph_t graph = nullptr;
    /* ThreadLocal 捕获模式: 只并本线程发起的操作 —— GLOBAL 模式会把并行线程
     * (如 NCCL 调用线程) 的无关 CUDA 调用拉进捕获而报 InvalidValue (ALGORITHMS §6) */
    if (cudaStreamBeginCapture(stream, cudaStreamCaptureModeThreadLocal) != cudaSuccess)
      return AR2_ERR_CUDA;
    for (int i = 0; i < n; i++) {
      Ar2OpPtrs pi = *p;   /* 全部 kernel 指向同一 claim 计数器, 执行序=claim 序 */
      pi.seq_ctr = seq_ctr;
      if (launch_one(xs[i], bytes[i], pi, stream) != AR2_OK) {
        cudaStreamEndCapture(stream, &graph);
        if (graph) cudaGraphDestroy(graph);
        return AR2_ERR_CUDA;
      }
    }
    if (cudaStreamEndCapture(stream, &graph) != cudaSuccess) return AR2_ERR_CUDA;
    cudaError_t e = cudaGraphInstantiate(&gexec, graph, 0);
    cudaGraphDestroy(graph);
    return e == cudaSuccess ? AR2_OK : AR2_ERR_CUDA;
  }

  int launch_graph(void *) override {
    if (!gexec) return AR2_ERR_INVALID;
    return cudaGraphLaunch(gexec, stream) == cudaSuccess ? AR2_OK : AR2_ERR_CUDA;
  }

  void sync_stream(void *) override {
    int64_t dl = now_ms() + 5000;   /* kernel abort 感知, 5s 上限防御 */
    while (cudaStreamQuery(stream) == cudaErrorNotReady && now_ms() < dl) spin_pause();
    cudaError_t e = cudaGetLastError();   /* 审计修复: 清理粘性错误前先留痕, finalize 期故障可诊断 */
    if (e != cudaSuccess)
      fprintf(stderr, "[ar2] sync_stream cuda err=%d (%s)\n", (int)e, cudaGetErrorString(e));
  }
};

}  // namespace

/* nothrow: 经 extern "C" 被 NCCL hook 调用, bad_alloc 穿透会 terminate (审计B-W2) */
Device *make_cuda_device() { return new (std::nothrow) CudaDevice(); }

}  // namespace ar2
