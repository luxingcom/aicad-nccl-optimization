// spcx_stub_tuner.c — simulate an external tuner plugin hijack (SPCX-like) for verifying
// PerSizeTuner dual-branch hardening (stageB-hardened-two-branch, ADR-014/015).
//
// This stub implements the NCCL tuner_v6 interface and deliberately sets a cost table
// that DIFFERS from our per-size LL/Simple policy (e.g. prefers LL128 + Simple over LL),
// to prove that with comm->tuner != NULL (if branch), ncclPersizeTunerOverride() still
// forces the LL/Simple two-band selection. Without the hardening this stub would silently
// defeat the per-size policy (the exact silent-failure risk we are eliminating).
//
// Build (in anemll image or on host with NCCL headers):
//   gcc -shared -fPIC -O2 -o spcx_stub_tuner.so spcx_stub_tuner.c \
//       -I<src>/src/include -I<src>/build/include
//
// Run (needs a real multi-rank collective, e.g. nccl-tests all_reduce_perf, in a window):
//   NCCL_TUNER_PLUGIN=/path/spcx_stub_tuner.so NCCL_TUNER_DEBUG=1 \
//       NCCL_ALGO=RING NCCL_PROTO=UNDEF ./build/test/all_reduce_perf -b 8 -e 262144 -f 2 -g 2 -n 10
// Expected: "PerSizeTuner: allreduce nBytes=40960 -> LL" for <=40KB, "-> Simple" for >40KB.
//
// Note: NCCL_TUNER_PLUGIN must point at a .so exporting ncclTunerPlugin_v6; getChunkSize
// is optional (NULL allowed) but we provide it to keep behavior closest to a real SPCX tuner.

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "nccl.h"
#include "plugin/nccl_tuner.h"

static ncclResult_t stub_init(void** ctx, uint64_t commId, size_t nRanks, size_t nNodes,
                              ncclDebugLogger_t logFunction, ncclNvlDomainInfo_v6_t* nvlDomainInfo,
                              ncclTunerConstants_v6_t* constants) {
  void** c = (void**)malloc(sizeof(void*));
  *c = NULL;
  *ctx = c;
  return ncclSuccess;
}

static ncclResult_t stub_getCollInfo(void* context, ncclFunc_t collType, size_t nBytes, int numPipeOps,
                                     float** collCostTable, int numAlgo, int numProto, int regBuff,
                                     int* nChannels) {
  // Simulate an SPCX-like tuner: flatten costs and mildly prefer LL128/SIMPLE regardless of size.
  // This intentionally CONFLICTS with our per-size policy; hardening must still win.
  float (*table)[NCCL_NUM_PROTOCOLS] = (float (*)[NCCL_NUM_PROTOCOLS])collCostTable;
  for (int a = 0; a < numAlgo; a++) {
    for (int p = 0; p < numProto; p++) {
      if (table[a][p] == NCCL_ALGO_PROTO_IGNORE) continue;
      // LL128 slightly preferred (cost 1.0), Simple 1.5, LL penalized (5.0) for all sizes.
      table[a][p] = (p == NCCL_PROTO_LL128) ? 1.0f : (p == NCCL_PROTO_SIMPLE ? 1.5f : 5.0f);
    }
  }
  // nChannels left untouched (NCCL core / topoGetAlgoInfo decides).
  return ncclSuccess;
}

static ncclResult_t stub_finalize(void* context) {
  free(context);
  return ncclSuccess;
}

static ncclResult_t stub_getChunkSize(void* context, ncclFunc_t collType, size_t nBytes, int algo, int proto,
                                      int nChannels, size_t* chunkSize) {
  // No override; keep NCCL computed chunk size.
  return ncclSuccess;
}

ncclTuner_v6_t ncclTunerPlugin_v6 = {
    "spcx-stub-sim",
    stub_init,
    stub_getCollInfo,
    stub_finalize,
    stub_getChunkSize,
};
