/*************************************************************************
 * tuner_per_size.c — NCCL per-size protocol tuner plugin (v6)
 *
 * 目标：decode 小 allreduce（1-16KB）走 LL 协议，prefill 大 allreduce 保持 Simple。
 * 机制：NCCL_TUNER_PLUGIN 动态加载 .so，导出 ncclTunerPlugin_v6，回调 getCollInfo
 *       （每次 collective planning 时调用，入参含真实 nBytes）。
 * 阈值：单边界 40KB（NCCL_TUNER_THRESHOLD 可覆盖）。
 *       ≤ threshold        -> 期望 proto = LL
 *       >  threshold        -> 期望 proto = Simple
 * 可选下界：NCCL_TUNER_LL_MIN（默认 0）——低于该字节数不切 LL（预留低端劣化保护）。
 * 纪律：
 *   - 只干预 allreduce（其余 collective 走 NCCL 默认，避免误伤 logits gather）。
 *   - 不碰 nChannels（保持生产已验证 MIN_CH4 / MAX_CH16 / BUFFSIZE=8M）。
 *   - 跳过 NCCL 标记为 NCCL_ALGO_PROTO_IGNORE 的不兼容组合。
 *   - 期望组合 cost 置 0.0f，其余置大数，强制 NCCL 选中期望协议。
 *
 * 编译（容器内，aarch64）：
 *   gcc -O2 -fPIC -shared -o libnccl_tuner_persize.so tuner_per_size.c -I.
 * 验证：
 *   nm -D libnccl_tuner_persize.so | grep ncclTunerPlugin_v6
 *
 * SPDX-License-Identifier: Apache-2.0
 *************************************************************************/

#include "nccl/tuner.h"
#include <stdio.h>
#include <stdlib.h>

#define TUNER_NAME         "PerSizeLLSimple"
#define DEFAULT_THRESHOLD  40960u   /* 40KB 单边界（Archi 定案） */
#define DEFAULT_LL_MIN     0u       /* LL 下界，默认不启用 */

typedef struct {
  size_t threshold;    /* ≤ threshold -> LL，> threshold -> Simple */
  size_t llMin;        /* < llMin 不切 LL（预留低端保护） */
  int    debug;        /* NCCL_TUNER_DEBUG=1 时打印每次选路 */
  ncclDebugLogger_t logFunction;
} TunerCtx;

static ncclResult_t tunerInit(void** context, uint64_t commId, size_t nRanks, size_t nNodes,
                              ncclDebugLogger_t logFunction,
                              ncclNvlDomainInfo_v5_t* nvlDomainInfo,
                              ncclTunerConstants_v5_t* constants) {
  (void)commId; (void)nvlDomainInfo; (void)constants;

  TunerCtx* ctx = (TunerCtx*)calloc(1, sizeof(TunerCtx));
  if (!ctx) return ncclSystemError;

  ctx->threshold = DEFAULT_THRESHOLD;
  ctx->llMin = DEFAULT_LL_MIN;
  ctx->logFunction = logFunction;
  ctx->debug = 0;

  const char* t = getenv("NCCL_TUNER_THRESHOLD");
  if (t) {
    long v = atol(t);
    if (v > 0) ctx->threshold = (size_t)v;
  }
  const char* m = getenv("NCCL_TUNER_LL_MIN");
  if (m) {
    long v = atol(m);
    if (v >= 0) ctx->llMin = (size_t)v;
  }
  if (getenv("NCCL_TUNER_DEBUG")) ctx->debug = 1;

  if (logFunction) {
    logFunction(NCCL_LOG_INFO, NCCL_TUNING, __FILE__, __LINE__,
                "TunerPerSize: init commId=%llu nRanks=%zu nNodes=%zu threshold=%zu llMin=%zu",
                (unsigned long long)commId, nRanks, nNodes, ctx->threshold, ctx->llMin);
  }

  *context = ctx;
  return ncclSuccess;
}

/* 按 nBytes 选期望协议；只处理 allreduce */
static ncclResult_t tunerGetCollInfo(void* context, ncclFunc_t collType, size_t nBytes,
                                     int numPipeOps, float** collCostTable,
                                     int numAlgo, int numProto, int regBuff, int* nChannels) {
  (void)numPipeOps; (void)regBuff; (void)nChannels;   /* v1 不碰 nChannels */

  TunerCtx* ctx = (TunerCtx*)context;
  if (!ctx) return ncclInternalError;

  /* 只干预 allreduce：decode 战场全是 allreduce；其余走 NCCL 默认 */
  if (collType != ncclFuncAllReduce) return ncclSuccess;

  int want;
  if (nBytes < ctx->llMin) {
    want = NCCL_PROTO_SIMPLE;      /* 低于下界不切 LL */
  } else if (nBytes <= ctx->threshold) {
    want = NCCL_PROTO_LL;          /* 小消息 -> LL */
  } else {
    want = NCCL_PROTO_SIMPLE;      /* 大消息 -> Simple */
  }

  /* collCostTable 是连续 [numAlgo][numProto] float 数组（以 float** 传入），
   * 必须按 NCCL 内部用法 cast 为 2D 数组指针访问（参考 enqueue.cc / example plugin）。 */
  float (*table)[NCCL_NUM_PROTOCOLS] = (float (*)[NCCL_NUM_PROTOCOLS])collCostTable;

  /* 修改 cost table：仅把期望协议的 cost 置 0.0（各非 IGNORE algo 均置），
   * 其余协议保留 NCCL 自算成本（正值）——保证选中期望协议且不引入危险大数。
   * 跳过 NCCL 已标记 IGNORE 的不兼容组合（不覆盖为可用）。 */
  for (int a = 0; a < numAlgo; a++) {
    for (int p = 0; p < numProto; p++) {
      if (table[a][p] == NCCL_ALGO_PROTO_IGNORE) continue;
      if (p == want) table[a][p] = 0.0f;
    }
  }

  if (ctx->debug && ctx->logFunction) {
    ctx->logFunction(NCCL_LOG_INFO, NCCL_TUNING, __FILE__, __LINE__,
                     "TunerPerSize: allreduce nBytes=%zu -> %s (threshold=%zu llMin=%zu)",
                     nBytes, (want == NCCL_PROTO_LL) ? "LL" : "Simple", ctx->threshold, ctx->llMin);
  }

  return ncclSuccess;
}

static ncclResult_t tunerFinalize(void* context) {
  TunerCtx* ctx = (TunerCtx*)context;
  if (ctx) free(ctx);
  return ncclSuccess;
}

/* v1 不覆盖 chunk size（getChunkSize = NULL，NCCL 使用自算 chunk） */
const ncclTuner_v6_t ncclTunerPlugin_v6 = {
  .name = TUNER_NAME,
  .init = tunerInit,
  .getCollInfo = tunerGetCollInfo,
  .finalize = tunerFinalize,
  .getChunkSize = NULL,
};
