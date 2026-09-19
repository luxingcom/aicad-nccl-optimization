/* ar2_dev_cpu.cpp — CPU 自测后端 (world=2: linkA 对端=对线程, linkB 自环)
 *
 * 用途: ar2_selftest 的执行体 —— 无 GPU/无 RDMA 环境下验证协议机与错误模型。
 * 语义镜像: op_submit 做与 kernel 相同的 device claim (__atomic_fetch_add);
 * prepare_milestone 0/1/2 逐拍复刻 kernel 的 stage/归约/终写 —— ar2_core 对两种
 * 后端的驱动序列完全一致, 协议逻辑可在 CPU 侧先行验证。
 * wait_dbell 与 kernel wait_two 同一套有界偏斜容忍规则 (d≤seq+1)。
 * dtype 仅支持 FP32 (CUDA 后端为 BF16; selftest D 组覆盖该契约)。 */
#include "ar2_internal.hpp"

#include <cstdlib>
#include <cstring>
#include <vector>

namespace ar2 {
namespace {

struct CpuDevice final : Device {
  int timeout_ms = 5000;
  std::vector<uint8_t *> arenas;   /* 审计B-W1 修复: 半失败泄漏防护 —— 登记所有分配,
                                    * 析构兜底释放 (与 CUDA 后端 arenas vector 对称);
                                    * 无此登记时 Link 建立失败路径的 arenaA/B 将泄漏 */
  /* env 优先级: 构造读 AR2_TIMEOUT_MS 只是 standalone 默认; ar2_init 随后必调
   * set_timeout(cfg.timeout_ms), cfg (含其 env 回退) 恒覆盖此值 */
  explicit CpuDevice(int dtype) {
    (void)dtype;
    const char *v = getenv("AR2_TIMEOUT_MS");
    if (v && *v) timeout_ms = atoi(v);
  }
  ~CpuDevice() override {
    for (auto *p : arenas) free(p);
  }
  const char *name() const override { return "cpu"; }
  void set_timeout(int ms) override { timeout_ms = ms; }
  uint8_t *arena_alloc(size_t bytes) override {
    void *p = nullptr;
    if (posix_memalign(&p, 4096, bytes)) return nullptr;
    memset(p, 0, bytes);
    arenas.push_back((uint8_t *)p);
    return (uint8_t *)p;
  }
  void arena_free(uint8_t *p) override {
    for (size_t i = 0; i < arenas.size(); i++)
      if (arenas[i] == p) {
        arenas.erase(arenas.begin() + (long)i);
        break;
      }
    free(p);
  }
  int op_submit(void *, uint8_t *x, uint32_t bytes, uint64_t seq, uint32_t slot,
                const Ar2OpPtrs &p) override {
    (void)seq;
    (void)slot;
    /* device 侧 claim 语义 (CUDA=kernel atomicAdd): CPU 用宿主原子对齐 */
    __atomic_fetch_add((uint64_t *)p.seq_ctr, 1, __ATOMIC_ACQ_REL);
    return AR2_OK;   /* 挂起 op; 各里程碑按引擎顺序推进 (参数全由里程碑携带, 无需暂存) */
  }
  /* 镜像 device kernel 的双等待语义 + abort/magic 检查 (d==0 = 未到达, 非错误);
   * 有界偏斜容忍: d==seq+1 合法早到 (槽数学保证 seq 数据完好), d>seq+1 = 错账 */
  int wait_dbell(volatile Ar2Ctl *L, uint64_t seq, volatile uint64_t *skew) {
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
      uint64_t d = ld_acquire(&L->dbell);
      if (d != 0 && !dbell_magic_ok(d)) return AR2_ERR_PROTOCOL;
      if (d != 0 && (dbell_flags(d) & 1)) return AR2_ERR_ABORTED;
      if (d != 0) {
        uint32_t diff = dbell_seq(d) - (uint32_t)seq;   /* 模 2^32 差 (审计修复 v2: 语义同 kernel) */
        if (diff == 0xFFFFFFFFu) {
          /* 未到达 */
        } else if (diff <= 1) {
          if (ld_acquire(&L->send_done) >= seq) {
            if (diff == 1 && skew) __atomic_fetch_add((uint64_t *)skew, 1, __ATOMIC_RELAXED);
            return AR2_OK;
          }
          /* 已到但 send_done 未就绪: 自旋 */
        } else {
          return AR2_ERR_PROTOCOL;
        }
      }
      if (ld_acquire(&L->abort)) return AR2_ERR_ABORTED;
      if (now_ms() > deadline) return AR2_ERR_TIMEOUT;
      spin_pause();
    }
  }
  /* R3 旗标镜像 (kernel wait_flag 的 CPU 同构): 无 send_done 门槛 (RC 有序放置),
   * abort 观测走所属链 ctl.abort; deadline 与 wait_dbell 同源 */
  int wait_flag(volatile Ar2Ctl *L, volatile uint64_t *flag, uint64_t seq) {
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
      uint64_t d = ld_acquire(flag);
      if (d != 0) {
        if (!dbell_magic_ok(d)) return AR2_ERR_PROTOCOL;
        if (dbell_flags(d) & 1) return AR2_ERR_ABORTED;
        uint32_t diff = dbell_seq(d) - (uint32_t)seq;
        if (diff == 0xFFFFFFFFu) {
          /* 未到达 */
        } else if (diff <= 1) {
          return AR2_OK;
        } else {
          return AR2_ERR_PROTOCOL;
        }
      }
      if (ld_acquire(&L->abort)) return AR2_ERR_ABORTED;
      if (now_ms() > deadline) return AR2_ERR_TIMEOUT;
      spin_pause();
    }
  }
  /* wait_dbell + nqp>1 时逐 q 补等旗标 (与 kernel 两处调用点的合成语义一致) */
  int wait_link(volatile Ar2Ctl *L, volatile uint64_t *flags, uint64_t seq, int nqp,
                volatile uint64_t *skew) {
    int rc = wait_dbell(L, seq, skew);
    if (rc) return rc;
    for (int q = 1; q < nqp; q++)
      if ((rc = wait_flag(L, flags + q, seq))) return rc;
    return AR2_OK;
  }
  int prepare_milestone(uint8_t *x, uint32_t bytes, uint64_t seq, uint32_t slot,
                        const Ar2OpPtrs &p, int milestone) override {
    size_t off = (size_t)slot * p.smax;   /* 槽步长 = smax, 与 post_burst 一致 */
    if (milestone == 0) {                 /* stage: x -> sendA, publish producer */
      memcpy(p.sendA + off, x, bytes);
      st_release(&p.ctlA->producer, seq);
      return AR2_OK;
    }
    int rc;
    size_t n = bytes / 4;
    int nqp = p.nqp > 0 ? p.nqp : 1;
    if (milestone == 1) {                 /* sB = sA + rA, publish arm1 */
      if ((rc = wait_link(p.ctlA, p.flagsA, seq, nqp, p.skew_ctr))) return rc;
      const float *a = (const float *)(p.sendA + off);
      const float *r = (const float *)(p.recvA + off);
      float *d = (float *)(p.sendB + off);
      for (size_t i = 0; i < n; i++) d[i] = a[i] + r[i];
      st_release(&p.ctlB->arm1, seq);
      return AR2_OK;
    }
    /* milestone 2: x = sB + rB, publish done */
    if ((rc = wait_link(p.ctlB, p.flagsB, seq, nqp, p.skew_ctr))) return rc;
    const float *s = (const float *)(p.sendB + off);
    const float *r = (const float *)(p.recvB + off);
    float *d = (float *)x;
    for (size_t i = 0; i < n; i++) d[i] = s[i] + r[i];
    st_release(&p.ctlB->done, seq);
    return AR2_OK;
  }
};

}  // namespace

/* nothrow: 本工厂经 extern "C" 边界被 NCCL hook 调用, bad_alloc 穿透会 terminate (审计B-W2) */
Device *make_cpu_device(int dtype) { return new (std::nothrow) CpuDevice(dtype); }

}  // namespace ar2
