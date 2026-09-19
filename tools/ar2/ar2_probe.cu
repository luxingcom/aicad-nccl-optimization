/* ar2_probe.cu — S2 四机 GPU 探针 (W3 定稿)
 * 用法: ar2_probe --rank R --peers ip0,ip1,ip2,ip3 --port 9500 \
 *             [--mode m1|layer] [--sizes 1024,4096,...] [--iters 200] [--warmup 20]
 *             [--die-after K]   # rank1 在第 K 个测量 op 后 _exit(9) 模拟死亡 (G3)
 * 逻辑 rank: 0=dgxspark01 1=dgxspark02 2=dgxspark04 3=dgxspark03 (环 0-1-2-3)
 *
 * 校验设计 (W3 教训沉淀, 改动前读 PITFALLS #11/#13/#15):
 *  - m1:   x=(rank+1), 全 4 rank 求和=10.0 (bf16 精确); 每 op 后独立校验 pass
 *  - layer: 整数指纹 buf i 初值 (rank+1)+2^(i-2) → 一次归约 = 10+2^i ∈{11..138}
 *    (全部 bf16 精确可表示; 同值累加 ×4 精确) —— 槽污染/错配会表现为 buf i 持有
 *    buf j 的指纹, 可直接指认肇事方
 *  - 时序循环**不做 H2D refill**: 默认流 memcpy 与 ar2 流 (非阻塞) 无同步,
 *    refill 会与尾 kernel 竞态制造"丢一代增长"伪影 (W3 M2 案真凶)
 *  - 周期校验期望 expect(i,t)=ldexpf(10+2^i, 2(t-1)), t=verify 后第 t 次调用;
 *    AR2_CHECK_EVERY 控制周期 (1=逐 op), AR2_NO_MIDCHECK 关闭
 * env: AR2_LAYER_NOPS(8) / AR2_DUMP(经库输出取证) / AR2_NO_GRAPH(走 M1 回退) 等 */
#include "ar2.h"

#include <cuda_bf16.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

#define AR2_MAX_LAYER_OPS 64   /* 须与 src/ar2_internal.hpp 同名宏一致 (探针独立编译不引内部头) */

using Clock = std::chrono::steady_clock;
static double us_between(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double, std::micro>(b - a).count();
}

static void report(const char *tag, uint32_t S, std::vector<double> &us) {
  std::sort(us.begin(), us.end());
  double s = 0;
  for (double v : us) s += v;
  printf("[ar2] %s S=%u avg=%.2f p50=%.2f p90=%.2f p99=%.2f min=%.2f\n", tag, S, s / us.size(),
         us[us.size() / 2], us[(size_t)(us.size() * 0.9)], us[(size_t)(us.size() * 0.99)], us[0]);
}

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  int rank = -1, port = 9500, iters = 200, warmup = 20, die_after = -1;
  std::string mode = "m1", sizes = "1024,4096,16384,32768,65536", peers;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--rank") && i + 1 < argc) rank = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--peers") && i + 1 < argc) peers = argv[++i];
    else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = argv[++i];
    else if (!strcmp(argv[i], "--sizes") && i + 1 < argc) sizes = argv[++i];
    else if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--warmup") && i + 1 < argc) warmup = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--die-after") && i + 1 < argc) die_after = atoi(argv[++i]);
    else { fprintf(stderr, "bad arg %s\n", argv[i]); return 2; }
  }
  if (iters < 1) iters = 1;   /* 审计修复: 防 us 空/越界 */
  if (rank < 0 || rank > 3 || peers.empty()) {
    fprintf(stderr, "usage: %s --rank R --peers ip0,ip1,ip2,ip3 [...]\n", argv[0]);
    return 2;
  }
  static std::string ipstore[4];   /* peer_ips 必须指向存活内存 (悬挂指针事故) */
  const char *ips[4] = {nullptr, nullptr, nullptr, nullptr};
  {
    char *tmp = strdup(peers.c_str());
    int n = 0;
    for (char *t = strtok(tmp, ","); t && n < 4; t = strtok(nullptr, ",")) {
      ipstore[n] = t;
      ips[n] = ipstore[n].c_str();
      n++;
    }
    if (n != 4) { fprintf(stderr, "need 4 peer ips\n"); return 2; }
    free(tmp);
  }
  std::vector<uint32_t> sz;
  {
    char *tmp = strdup(sizes.c_str());
    for (char *t = strtok(tmp, ","); t; t = strtok(nullptr, ",")) sz.push_back((uint32_t)atoi(t));
    free(tmp);
  }

  ar2_config cfg;
  ar2_config_defaults(&cfg);
  cfg.rank = rank;
  cfg.world = 4;
  for (int r = 0; r < 4; r++) cfg.peer_ips[r] = ips[r];
  cfg.ctrl_port = port;
  cfg.dev0 = "rocep1s0f1";
  cfg.dev1 = "roceP2p1s0f0";
  cfg.dtype = AR2_DT_BF16;
  cfg.backend = AR2_BACKEND_CUDA;
  cfg.timeout_ms = 5000;
  ar2_comm *c = nullptr;
  int rc = ar2_init(&cfg, &c);
  printf("[init] rank%d ar2_init rc=%d (%s)\n", rank, rc, ar2_strerror(rc));
  if (rc != AR2_OK) return 1;

  /* smax 与 ar2_init 的 env 回退同源 (AR2_SMAX, 默认 65536); R3 大尺寸微基准 (≤512KB)
   * 靠 env 抬高 —— 此处本地副本必须跟随, 否则 S>smax 被静默跳过 */
  uint32_t smax = 65536;
  {
    const char *se = getenv("AR2_SMAX");
    if (se && *se) smax = (uint32_t)strtoul(se, nullptr, 10);
  }
  std::vector<__nv_bfloat16> h(smax / 2), chk(smax / 2);
  void *d = nullptr;
  if (cudaMalloc(&d, smax) != cudaSuccess) { printf("[probe] cudaMalloc d fail\n"); return 1; }
  auto fill = [&](float v) {
    for (size_t i = 0; i < smax / 2; i++) h[i] = __float2bfloat16(v);
    cudaMemcpy(d, h.data(), smax, cudaMemcpyHostToDevice);
  };
  auto verify = [&](uint32_t bytes) {
    cudaMemcpy(chk.data(), d, bytes, cudaMemcpyDeviceToHost);
    float expect = 10.0f;
    for (uint32_t i = 0; i < bytes / 2; i++)
      if (__bfloat162float(chk[i]) != expect) {
        printf("[check] rank%d WRONG @%u: %.3f != %.1f\n", rank, i, __bfloat162float(chk[i]), expect);
        return false;
      }
    return true;
  };

  int failures = 0;
  if (mode == "m1") {
    for (uint32_t S : sz) {
      if (S > smax) continue;
      fill((float)(rank + 1));
      /* 校验独立 pass: 单 op + verify */
      if ((rc = ar2_allreduce(c, d, S)) != AR2_OK || !verify(S)) {
        printf("[ar2] rank%d S=%u CHECK FAIL rc=%d\n", rank, S, rc);
        failures++;
      }
      fill((float)(rank + 1));
      std::vector<double> us(iters);
      int aborted = 0;
      for (int it = 0; it < warmup + iters; it++) {
        if (die_after > 0 && rank == 1 && it == warmup + die_after) {
          printf("[die] rank1 exiting at op %d\n", die_after);
          fflush(stdout);
          _exit(9);
        }
        auto t0 = Clock::now();
        rc = ar2_allreduce(c, d, S);
        auto t1 = Clock::now();
        if (rc != AR2_OK) {
          printf("[ar2] rank%d S=%u op rc=%d (%s) at iter %d\n", rank, S, rc, ar2_strerror(rc), it);
          aborted = 1;
          break;
        }
        if (it >= warmup) us[it - warmup] = us_between(t0, t1);
      }
      if (aborted) { failures++; break; }
      report("m1", S, us);
    }
  } else if (mode == "layer") {
    int NOPS = getenv("AR2_LAYER_NOPS") ? atoi(getenv("AR2_LAYER_NOPS")) : 8;
    if (NOPS < 1 || NOPS > AR2_MAX_LAYER_OPS) NOPS = 8;
    void *db[AR2_MAX_LAYER_OPS] = {};   /* 仅 [0,NOPS) 有效; 零初始化防误用误报 */
    uint32_t bsz[AR2_MAX_LAYER_OPS] = {};
    /* 整数指纹: buf i 初值 (rank+1)+2^(i-2), 一次归约后 = 10+2^i ∈ {11..138} 全精确;
     * 槽污染/错配会表现为 buf i 持有 buf j 的指纹 → 直接指认肇事 kernel */
    auto fill_buf = [&](int i, uint32_t bytes) {
      float v = (float)(rank + 1) + ldexpf(1.0f, i - 2);
      for (uint32_t k = 0; k < bytes / 2; k++) h[k] = __float2bfloat16(v);
      cudaMemcpy(db[i], h.data(), bytes, cudaMemcpyHostToDevice);
    };
    auto expect1 = [&](int i) { return 10.0f + (float)((1 << i)); };   /* 一次归约后期望 */
    for (int i = 0; i < NOPS; i++) {
      if (cudaMalloc(&db[i], smax) != cudaSuccess) { printf("[probe] cudaMalloc db%d fail\n", i); return 1; }
      bsz[i] = 12288;   /* DSV4 hidden 6144 × bf16 = 12288B 生产几何 */
      fill_buf(i, smax);
    }
    for (uint32_t S : sz) {
      for (int i = 0; i < NOPS; i++) { bsz[i] = S; fill_buf(i, S); }
      rc = ar2_capture_layer(c, db, bsz, NOPS);
      if (rc != AR2_OK && rc != AR2_ERR_UNSUPPORTED) {
        printf("[ar2] rank%d capture rc=%d\n", rank, rc);
        failures++;
        break;
      }
      if ((rc = ar2_allreduce_layer(c, db, bsz, NOPS)) != AR2_OK) {
        printf("[ar2] rank%d layer rc=%d\n", rank, rc);
        failures++;
        break;
      }
      bool ok = true;
      for (int i = 0; i < NOPS && ok; i++) {
        cudaMemcpy(chk.data(), db[i], S, cudaMemcpyDeviceToHost);
        float e1 = expect1(i);
        for (uint32_t j = 0; j < S / 2; j++)
          if (__bfloat162float(chk[j]) != e1) {
            printf("[check] rank%d layer buf%d WRONG @%u: %g != %g\n", rank, i, j,
                   __bfloat162float(chk[j]), e1);
            ok = false;
          }
      }
      if (!ok) { failures++; break; }
      /* 不再 refill: H2D 重置 (默认流) 会与 ar2 流尾 kernel 的最终写竞态, 平白丢一代增长
       * (W2-M2 教训: 曾被误判为"冻结")。verify 后 x = base_i, 时序每调用 ×4, 期望 = base×4^(it+1) */
      std::vector<double> us(iters);
      int midcheck = getenv("AR2_NO_MIDCHECK") ? 0 : 1;   /* 可关: 排除校验同步对时序的扰动 */
      int checkev = getenv("AR2_CHECK_EVERY") ? atoi(getenv("AR2_CHECK_EVERY")) : 50;
      if (checkev < 1) checkev = 50;
      for (int it = 0; it < warmup + iters; it++) {
        auto t0 = Clock::now();
        rc = ar2_allreduce_layer(c, db, bsz, NOPS);
        auto t1 = Clock::now();
        if (rc != AR2_OK) { failures++; break; }
        if (it >= warmup) us[it - warmup] = us_between(t0, t1) / NOPS;
        /* 审计修复: it+1≥60 后值与期望双双溢出为 inf (inf==inf 恒过), 校验空转 — 截止到 60 */
        if (midcheck && it > 0 && it + 1 < 60 && it % checkev == 0) {   /* 期望 = (10+2^i)×4^(it+1), 整数精确 */
          bool cok = true;
          for (int i = 0; i < NOPS; i++) {
            float expect = ldexpf(expect1(i), 2 * (it + 1));   /* verify 后已 base, it+1 次调用 → ×4^(it+1) */
            cudaMemcpy(chk.data(), db[i], S, cudaMemcpyDeviceToHost);
            for (uint32_t j = 0; j < S / 2 && cok; j++)
              if (__bfloat162float(chk[j]) != expect) {
                printf("[check] rank%d iter%d buf%d WRONG @%u: %g != %g\n",
                       rank, it, i, j, __bfloat162float(chk[j]), expect);
                cok = false;
              }
          }
          if (!cok) {   /* 指纹行: 全 buf 首元素 → 一眼看出谁冻结/谁被污染 */
            printf("[fp] rank%d iter%d:", rank, it);
            for (int i = 0; i < NOPS; i++) {
              cudaMemcpy(chk.data(), db[i], sizeof(__nv_bfloat16), cudaMemcpyDeviceToHost);
              printf(" b%d=%g", i, __bfloat162float(chk[0]));
            }
            printf("\n");
            failures++;
            rc = AR2_ERR_INVALID;
            break;
          }
        }
      }
      if (rc != AR2_OK) break;
      report("layer8", S, us);
    }
  }
  ar2_finalize(&c);
  cudaFree(d);
  printf("[done] rank%d failures=%d\n", rank, failures);
  return failures ? 1 : 0;
}
