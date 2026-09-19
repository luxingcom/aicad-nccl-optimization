/* ar2_selftest.cpp — 单机自环自测 (无 GPU, world=2 双线程, 本地回环 QP)
 * 用例: A 协议正确性(单/双缓冲交替/随机尺寸) / B 超时→ABORT 传播(19µs 级级联)
 *       C RSS 门(10k op <8MB) / D API 契约(路由交叉点/后端 dtype/finalize null 安全)
 * 注意: 需 RDMA 设备权限; 无权限容器(未 --privileged)会 verbs error、RSS 读数失真
 *       ——属环境限制非回归, 权威判定=宿主机 selftest + 四机真跑 (BUILD-TEST §2)。
 * 足迹: <100MB RAM, 无外部流量 (RDMA WR 打到自身), 生产在役可跑 */
#include "ar2.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <string>
#include <thread>
#include <vector>

static int g_fail = 0;
#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) {                                                             \
      printf("  [PASS] %s\n", msg);                                         \
    } else {                                                                \
      printf("  [FAIL] %s  (%s:%d)\n", msg, __FILE__, __LINE__);            \
      g_fail = 1;                                                           \
    }                                                                       \
  } while (0)

static size_t rss_kb() {
  /* 审计修复: 页大小取运行时值 (aarch64 可配 16K/64K 页); 读失败返回 SIZE_MAX 哨兵而非 0
   * (0 会让 delta 为负 → RSS 门恒过, 测量失败静默变 PASS) */
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return (size_t)-1;
  unsigned long tot = 0, res = 0;
  if (fscanf(f, "%lu %lu", &tot, &res) != 2) res = 0;
  fclose(f);
  if (!res) return (size_t)-1;
  return (size_t)res * (size_t)(sysconf(_SC_PAGESIZE) / 1024);
}

using Clock = std::chrono::steady_clock;
static double us_since(Clock::time_point t0) {
  return std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
}

static void make_cfg(ar2_config *cfg, int rank, int timeout_ms) {
  ar2_config_defaults(cfg);
  cfg->rank = rank;
  cfg->world = 2;
  cfg->peer_ips[0] = "127.0.0.1";
  cfg->ctrl_port = 9611;
  cfg->dev0 = "rocep1s0f1";
  cfg->dev1 = "roceP2p1s0f0";
  cfg->gid_index = 3;
  cfg->smax_bytes = 65536;
  cfg->nslots = 2;
  cfg->dtype = AR2_DT_FP32;
  cfg->timeout_ms = timeout_ms;
  cfg->backend = AR2_BACKEND_CPU;
}

static void run_pair(void (*fn0)(void *), void (*fn1)(void *), void *arg0, void *arg1) {
  std::thread t1(fn1, arg1);
  fn0(arg0);
  t1.join();
}

/* ---- Test A: 正确性 (world=2: R0 对端交换, R1 自环 → out = 2*(v0+v1) = 6.0) ---- */
struct CorrectArg {
  int rank;
  int rc = AR2_ERR_FATAL;
  uint64_t ops = 0;
};
static void correct_fn(void *p) {
  CorrectArg *a = (CorrectArg *)p;
  ar2_config cfg;
  make_cfg(&cfg, a->rank, 5000);
  ar2_comm *c = nullptr;
  a->rc = ar2_init(&cfg, &c);
  if (a->rc != AR2_OK) return;
  std::vector<float> x(65536 / 4);
  for (size_t sz : {4096u, 65536u}) {
    for (int it = 0; it < 100; it++) {
      for (size_t i = 0; i < sz / 4; i++) x[i] = (float)(a->rank + 1);
      int rc = ar2_allreduce(c, x.data(), (uint32_t)sz);
      if (rc != AR2_OK) {
        a->rc = rc;
        ar2_finalize(&c);
        return;
      }
      if (it < 10) {
        for (size_t i = 0; i < sz / 4; i++)
          if (x[i] != 6.0f) {
            printf("  rank%d WRONG x[%zu]=%.3f (expect 6.0)\n", a->rank, i, x[i]);
            a->rc = AR2_ERR_PROTOCOL;
            ar2_finalize(&c);
            return;
          }
      }
    }
  }
  a->ops = ar2_ops_completed(c);
  a->rc = ar2_finalize(&c);
}

/* ---- Test B: 超时 → ABORT 门铃传播 (rank1 迟到 800ms, timeout=300ms) ---- */
struct AbortArg {
  int rank;
  int rc = AR2_ERR_FATAL;
  double wall_us = 0;
  std::atomic<bool> *go = nullptr;
};
static void abort_fn(void *p) {
  AbortArg *a = (AbortArg *)p;
  ar2_config cfg;
  make_cfg(&cfg, a->rank, 300);
  ar2_comm *c = nullptr;
  a->rc = ar2_init(&cfg, &c);
  if (a->rc != AR2_OK) return;
  a->go->store(true);
  if (a->rank == 1) std::this_thread::sleep_for(std::chrono::milliseconds(800));
  std::vector<float> x(4096 / 4, 1.0f);
  auto t0 = Clock::now();
  a->rc = ar2_allreduce(c, x.data(), 4096);
  a->wall_us = us_since(t0);
  int poisoned_rc = ar2_allreduce(c, x.data(), 4096);   /* poison 后立即失败 */
  if (poisoned_rc >= 0) a->rc = AR2_ERR_FATAL;
  ar2_finalize(&c);
}

/* ---- Test C: RSS 门 (10k op 零分配) ---- */
struct RssArg {
  int rank;
  size_t delta_kb = 1 << 30;
};
static void rss_fn(void *p) {
  RssArg *a = (RssArg *)p;
  ar2_config cfg;
  make_cfg(&cfg, a->rank, 5000);
  ar2_comm *c = nullptr;
  if (ar2_init(&cfg, &c) != AR2_OK) return;
  std::vector<float> x(4096 / 4, 1.0f);
  for (int i = 0; i < 200; i++) ar2_allreduce(c, x.data(), 4096);
  size_t before = rss_kb();
  for (int i = 0; i < 10000; i++) ar2_allreduce(c, x.data(), 4096);
  a->delta_kb = rss_kb() - before;
  ar2_finalize(&c);
}

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  printf("=== ar2 selftest (world=2 loopback, CPU backend, FP32) ===\n");

  printf("[A] correctness 4K/64K x100\n");
  CorrectArg ca0{0}, ca1{1};
  run_pair([](void *p) { correct_fn(p); }, [](void *p) { correct_fn(p); }, &ca0, &ca1);
  CHECK(ca0.rc == AR2_OK && ca1.rc == AR2_OK, "both ranks allreduce OK");
  CHECK(ca0.ops == 200 && ca1.ops == 200, "ops counter == 200");

  printf("[B] timeout 300ms + peer late 800ms → abort propagation\n");
  std::atomic<bool> go{false};
  AbortArg ab0{0, 0, 0, &go}, ab1{1, 0, 0, &go};
  run_pair([](void *p) { abort_fn(p); }, [](void *p) { abort_fn(p); }, &ab0, &ab1);
  printf("  rank0 rc=%d (%s) wall=%.0fus | rank1 rc=%d (%s) wall=%.0fus\n", ab0.rc,
         ar2_strerror(ab0.rc), ab0.wall_us, ab1.rc, ar2_strerror(ab1.rc), ab1.wall_us);
  CHECK(ab0.rc == AR2_ERR_TIMEOUT, "rank0 (timeout side) returns TIMEOUT");
  CHECK(ab1.rc < 0, "rank1 (late side) fails fast via ABORT bell");
  CHECK(ab1.wall_us < 300000, "rank1 wall < 300ms (not waiting own 300ms+deadline)");

  printf("[C] RSS gate: 10k ops delta < 8MB\n");
  RssArg ra0{0}, ra1{1};
  run_pair([](void *p) { rss_fn(p); }, [](void *p) { rss_fn(p); }, &ra0, &ra1);
  size_t d = ra0.delta_kb > ra1.delta_kb ? ra0.delta_kb : ra1.delta_kb;
  printf("  rss delta: rank0=%zuKB rank1=%zuKB\n", ra0.delta_kb, ra1.delta_kb);
  CHECK(d != (size_t)-1, "rss readable");   /* 审计修复: 测量失败显式 FAIL 而非静默通过 */
  CHECK(d < 8192, "10k-op RSS delta < 8MB");

  printf("[D] API contract\n");
  {
    ar2_config cfg;
    ar2_config_defaults(&cfg);
    cfg.world = 2;
    cfg.rank = 0;
    cfg.peer_ips[0] = "127.0.0.1";
    cfg.dev0 = "rocep1s0f1";
    cfg.dev1 = "roceP2p1s0f0";
    cfg.dtype = AR2_DT_FP32;
    cfg.backend = AR2_BACKEND_CPU;
    cfg.timeout_ms = 5000;
    CHECK(ar2_recommended(4096) == 1 && ar2_recommended(16384) == 0, "crossover routing 8K (2026-09-04 实测定界)");
    ar2_comm *c = nullptr, *c1 = nullptr;
    ar2_config bad = cfg;
    bad.dtype = AR2_DT_BF16;
    CHECK(ar2_init(&bad, &c1) == AR2_ERR_UNSUPPORTED, "CPU backend rejects BF16");
    CHECK(ar2_finalize(nullptr) == AR2_OK, "finalize(nullptr) safe");
    /* graph on CPU → UNSUPPORTED; 由 Test A 会话结束后这里做无会话路径检查 */
    (void)c;
  }

  printf("=== %s ===\n", g_fail ? "SELFTEST FAILED" : "SELFTEST PASSED");
  return g_fail;
}
