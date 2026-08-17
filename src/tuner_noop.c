/*************************************************************************
 * tuner_noop.c — 最小 no-op 插件：只验证【加载插件本身】对 net 连接的影响
 * 逻辑：init 分配 context；getCollInfo 不做任何修改直接返回 ncclSuccess；
 *       finalize 释放。不含任何 cost table 操作。
 * 用途：隔离"插件加载" vs "cost table 修改" 对 ring-only P2 lib net 路径的影响。
 *************************************************************************/

#include "nccl/tuner.h"
#include <stdlib.h>

typedef struct { int dummy; } NoopCtx;

static ncclResult_t noopInit(void** context, uint64_t commId, size_t nRanks, size_t nNodes,
                             ncclDebugLogger_t logFunction,
                             ncclNvlDomainInfo_v5_t* nvlDomainInfo,
                             ncclTunerConstants_v5_t* constants) {
  (void)commId; (void)nRanks; (void)nNodes; (void)logFunction;
  (void)nvlDomainInfo; (void)constants;
  NoopCtx* ctx = (NoopCtx*)calloc(1, sizeof(NoopCtx));
  if (!ctx) return ncclSystemError;
  if (logFunction) {
    logFunction(NCCL_LOG_INFO, NCCL_TUNING, __FILE__, __LINE__,
                "TunerNoop: init (load test only)");
  }
  *context = ctx;
  return ncclSuccess;
}

static ncclResult_t noopGetCollInfo(void* context, ncclFunc_t collType, size_t nBytes,
                                    int numPipeOps, float** collCostTable,
                                    int numAlgo, int numProto, int regBuff, int* nChannels) {
  (void)context; (void)collType; (void)nBytes; (void)numPipeOps;
  (void)collCostTable; (void)numAlgo; (void)numProto; (void)regBuff; (void)nChannels;
  return ncclSuccess;   /* 完全不动 cost table */
}

static ncclResult_t noopFinalize(void* context) {
  if (context) free(context);
  return ncclSuccess;
}

const ncclTuner_v6_t ncclTunerPlugin_v6 = {
  .name = "NoopTuner",
  .init = noopInit,
  .getCollInfo = noopGetCollInfo,
  .finalize = noopFinalize,
  .getChunkSize = NULL,
};
