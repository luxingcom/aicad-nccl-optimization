#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply 2-hop proto (Form A-minimal) changes to NCCL 2.30.7 tree.
Rex / SRE, 2026-08-16. Idempotent-ish (fails if a marker already present)."""
import os
import sys

ROOT = "/opt/2hop-s1/src/nccl-2hop-proto"

def patch_file(rel, old, new, marker):
    path = os.path.join(ROOT, rel)
    with open(path, "r", encoding="utf-8") as f:
        s = f.read()
    if marker in s:
        print(f"[skip] {rel}: marker already present")
        return
    if old not in s:
        print(f"[FAIL] {rel}: anchor not found!")
        sys.exit(1)
    s = s.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"[ok] {rel}")

# ---------------------------------------------------------------------------
# 1. src/include/plugin/nccl_tuner.h : add NCCL_ALGO_2HOP, bump count 7->8
# ---------------------------------------------------------------------------
patch_file(
    "src/include/plugin/nccl_tuner.h",
    """#define NCCL_ALGO_PAT 6
#define NCCL_NUM_ALGORITHMS NCCL_NUM_ALGORITHMS_V5 // Tree/Ring/CollNet*/PAT""",
    """#define NCCL_ALGO_PAT 6
#define NCCL_ALGO_2HOP 7 // AICAD 2-hop proto (Form A-minimal, test-only)
#define NCCL_NUM_ALGORITHMS NCCL_NUM_ALGORITHMS_V5 // Tree/Ring/CollNet*/PAT/2HOP""",
    "NCCL_ALGO_2HOP 7",
)

patch_file(
    "src/include/plugin/tuner/tuner_v5.h",
    "#define NCCL_NUM_ALGORITHMS_V5 7 // Tree/Ring/CollNet*/PAT",
    "#define NCCL_NUM_ALGORITHMS_V5 8 // Tree/Ring/CollNet*/PAT/2HOP (AICAD proto)",
    "NCCL_NUM_ALGORITHMS_V5 8",
)

# ---------------------------------------------------------------------------
# 2. src/init.cc : ncclAlgoStr + graphs[] mapping (2HOP -> ring graph)
# ---------------------------------------------------------------------------
patch_file(
    "src/init.cc",
    """const char* ncclAlgoStr[NCCL_NUM_ALGORITHMS] = {"Tree",     "Ring", "CollNetDirect", "CollNetChain", "NVLS",
                                                "NVLSTree", "PAT"};""",
    """const char* ncclAlgoStr[NCCL_NUM_ALGORITHMS] = {"Tree",     "Ring", "CollNetDirect", "CollNetChain", "NVLS",
                                                "NVLSTree", "PAT", "2HOP"};""",
    '"2HOP"};',
)

patch_file(
    "src/init.cc",
    """  struct ncclTopoGraph* graphs[NCCL_NUM_ALGORITHMS] = {treeGraph, ringGraph, collNetDirectGraph, collNetChainGraph,
                                                       nvlsGraph, nvlsGraph, treeGraph};""",
    """  struct ncclTopoGraph* graphs[NCCL_NUM_ALGORITHMS] = {treeGraph, ringGraph, collNetDirectGraph, collNetChainGraph,
                                                       nvlsGraph, nvlsGraph, treeGraph, ringGraph};""",
    "ringGraph}; // AICAD 2HOP",
)

# ---------------------------------------------------------------------------
# 3. src/graph/tuning.cc : maxThreads for 2HOP = ring
# ---------------------------------------------------------------------------
patch_file(
    "src/graph/tuning.cc",
    """  comm->maxThreads[NCCL_ALGO_RING][NCCL_PROTO_LL128] = comm->maxThreads[NCCL_ALGO_TREE][NCCL_PROTO_LL128] =
    getNthreads("NCCL_LL128_NTHREADS", ncclParamLl128Nthreads(), NCCL_LL128_MAX_NTHREADS / 4, NCCL_LL128_MAX_NTHREADS,
                NCCL_LL128_MAX_NTHREADS);""",
    """  comm->maxThreads[NCCL_ALGO_RING][NCCL_PROTO_LL128] = comm->maxThreads[NCCL_ALGO_TREE][NCCL_PROTO_LL128] =
    getNthreads("NCCL_LL128_NTHREADS", ncclParamLl128Nthreads(), NCCL_LL128_MAX_NTHREADS / 4, NCCL_LL128_MAX_NTHREADS,
                NCCL_LL128_MAX_NTHREADS);
  // AICAD 2-hop proto: reuse ring thread config (structurally a ring-like kernel).
  comm->maxThreads[NCCL_ALGO_2HOP][NCCL_PROTO_SIMPLE] = comm->maxThreads[NCCL_ALGO_RING][NCCL_PROTO_SIMPLE];
  comm->maxThreads[NCCL_ALGO_2HOP][NCCL_PROTO_LL] = comm->maxThreads[NCCL_ALGO_RING][NCCL_PROTO_LL];
  comm->maxThreads[NCCL_ALGO_2HOP][NCCL_PROTO_LL128] = comm->maxThreads[NCCL_ALGO_RING][NCCL_PROTO_LL128];""",
    "AICAD 2-hop proto: reuse ring thread config",
)

# ---------------------------------------------------------------------------
# 4. src/device/all_reduce.h : run2Hop kernel + dispatch
# ---------------------------------------------------------------------------
kernel = r'''
/* ============================================================
 * AICAD 2-hop allreduce proto (Form A-minimal, test-only).
 *   - 4-rank schedule: RS(2)+AG(2) (vs ring RS(3)+AG(3)).
 *   - Bilateral steps use BOTH ring edges via two Primitives
 *     objects on disjoint connections:
 *       primsFwd : send->next (ring->next), recv<-prev (ring->prev)
 *       primsBwd : send->prev (ring->prev), recv<-next (ring->next)
 *     group offset = Proto::MaxGroupWidth (treeSplit pattern).
 *   - In-place only (sendbuff==recvbuff) so recvReduceCopy
 *     accumulates (input[off]==output[off]); out-of-place falls
 *     back to runRing for safety.
 *   - Data volume/rank = 7 chunks = 1.75S (proto incl. P4 fix).
 *   - Schedule matches twohop_algo.py mock (S1 validated).
 * ============================================================ */
template <typename T, typename RedOp, typename Proto>
__device__ __forceinline__ void run2Hop(int tid, int nthreads, struct ncclDevWorkColl* work) {
  const int nranks = ncclShmem.comm.nRanks;
  if (nranks != 4 || work->sendbuff != work->recvbuff) {
    // Proto scope: 4-rank in-place only; otherwise use the (correct) ring path.
    runRing<T, RedOp, Proto>(tid, nthreads, work);
    return;
  }
  ncclRing* ring = &ncclShmem.channel.ring;
  const int ringIx = ring->index;
  ssize_t gridOffset;
  ssize_t channelCount;
  ssize_t chunkCount;
  ncclCollCbdPart(work, ncclShmem.channelId, Proto::Id, sizeof(T), (ssize_t*)nullptr, &gridOffset, &channelCount,
                  &chunkCount);
  const ssize_t loopCount = nranks * chunkCount;

  Primitives<T, RedOp, FanSymmetric<1>, 1, Proto, 0> primsFwd(tid, nthreads, &ring->prev, &ring->next, work->sendbuff,
                                                              work->recvbuff, work->redOpArg, 0, 0, 0, work);
  Primitives<T, RedOp, FanSymmetric<1>, 1, Proto, 0> primsBwd(tid, nthreads, &ring->next, &ring->prev, work->sendbuff,
                                                              work->recvbuff, work->redOpArg, Proto::MaxGroupWidth, 0,
                                                              0, work);

  for (ssize_t elemOffset = 0; elemOffset < channelCount; elemOffset += loopCount) {
    ssize_t remCount = channelCount - elemOffset;
    ssize_t c = chunkCount;
    if (remCount < loopCount) c = alignUp(divUp(remCount, nranks), 16 / sizeof(T));
    auto off = [&](int ci) __device__ -> ssize_t {
      int k = ci % nranks;
      if (k < 0) k += nranks;
      return gridOffset + elemOffset + k * c;
    };
    auto ne = [&](int ci) __device__ -> ssize_t {
      int k = ci % nranks;
      if (k < 0) k += nranks;
      ssize_t base = k * c;
      return min(c, remCount - base);
    };

    // ---------------- RS step 1 (bilateral) ----------------
    primsFwd.send(off(ringIx + 1), ne(ringIx + 1));                        // c_{r+1} -> next
    primsFwd.send(off(ringIx + 2), ne(ringIx + 2));                        // c_{r+2} -> next
    primsFwd.recvReduceCopy(off(ringIx), off(ringIx), ne(ringIx));        // x[r] += R_{r+1} (c_r from prev)
    primsFwd.recv(off(ringIx + 1), ne(ringIx + 1));                        // carry = R_{r-1} c_{r+1}
    primsBwd.send(off(ringIx - 1), ne(ringIx - 1));                        // c_{r-1} -> prev
    primsBwd.recvReduceCopy(off(ringIx), off(ringIx), ne(ringIx));        // x[r] += R_{r-1} (c_r from next)

    // ---------------- RS step 2 (forward) ----------------
    primsFwd.send(off(ringIx + 1), ne(ringIx + 1));                        // carry c_{r+1} -> next
    primsFwd.recvReduceCopy(off(ringIx), off(ringIx), ne(ringIx));        // x[r] += R_{r-2} -> fully reduced

    // ---------------- AG step 3 (bilateral) ----------------
    primsFwd.sendFromOutput(off(ringIx), ne(ringIx));                     // c_r* -> next
    primsFwd.recv(off(ringIx - 1), ne(ringIx - 1));                       // c_{r-1}* <- prev -> x[r-1]
    primsBwd.sendFromOutput(off(ringIx), ne(ringIx));                     // c_r* -> prev
    primsBwd.recv(off(ringIx + 1), ne(ringIx + 1));                       // c_{r+1}* <- next -> x[r+1] (fwd src)

    // ---------------- AG step 4 (forward) ----------------
    primsBwd.sendFromOutput(off(ringIx + 1), ne(ringIx + 1));            // fwd c_{r+1}* -> prev
    primsBwd.recv(off(ringIx + 2), ne(ringIx + 2));                       // c_{r+2}* <- next -> x[r+2]
  }
}
''' + "\n} // namespace\n"

patch_file(
    "src/device/all_reduce.h",
    "} // namespace\n",
    kernel,
    "run2Hop",
)

# Dispatch specializations appended at end of file
dispatch = r'''
template <typename T, typename RedOp>
struct RunWorkColl<ncclFuncAllReduce, T, RedOp, NCCL_ALGO_2HOP, NCCL_PROTO_SIMPLE> {
  __device__ __forceinline__ void run(int tid, int nthreads, struct ncclDevWorkColl* work) {
    using Proto = ProtoSimple<ALLREDUCE_CHUNKSTEPS / ALLREDUCE_SLICESTEPS, ALLREDUCE_SLICESTEPS>;
    run2Hop<T, RedOp, Proto>(tid, nthreads, work);
  }
};

template <typename T, typename RedOp>
struct RunWorkColl<ncclFuncAllReduce, T, RedOp, NCCL_ALGO_2HOP, NCCL_PROTO_LL> {
  __device__ __forceinline__ void run(int tid, int nthreads, struct ncclDevWorkColl* work) {
    run2Hop<T, RedOp, ProtoLL>(tid, nthreads, work);
  }
};

template <typename T, typename RedOp>
struct RunWorkColl<ncclFuncAllReduce, T, RedOp, NCCL_ALGO_2HOP, NCCL_PROTO_LL128> {
  __device__ __forceinline__ void run(int tid, int nthreads, struct ncclDevWorkColl* work) {
    run2Hop<T, RedOp, ProtoLL128>(tid, nthreads, work);
  }
};
'''

tail = os.path.join(ROOT, "src/device/all_reduce.h")
with open(tail, "r", encoding="utf-8") as f:
    s = f.read()
if "NCCL_ALGO_2HOP, NCCL_PROTO_SIMPLE" in s:
    print("[skip] dispatch already present")
else:
    with open(tail, "a", encoding="utf-8") as f:
        f.write(dispatch)
    print("[ok] all_reduce.h dispatch appended")

print("DONE")
