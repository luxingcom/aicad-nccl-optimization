#!/usr/bin/env python3
"""P0-2: 反转机制复现诊断 (adjudication §3/§5.2, architect refinement).

Hypothesis: 2hop @1K nobar(868us) > aligned(471us) inversion is a torch
"single-PG op-matching + dual-port step pipelined backpressure" artifact.

Test: run twohop_allreduce AND manual_ring_allreduce (internal control) in 3
transport modes, wall-clock total:
  A) singlePG_nobar : current NcclTransport (batch all step ops on ONE PG)
  B) twoPG_nobar    : TwoPGTransport — each ring EDGE assigned to one of 2 PGs
                      (edge index parity), so a rank's two ports run on separate
                      NCCL communicators (genuine dual-communicator concurrency),
                      AND both ends of a link match on the same PG.
  C) singlePG_aligned: reference (barrier-per-step) single PG

NOTE on routing (SRE flag): architect's literal "local direction" rule
(peer=(r+1)->PG_R, peer=(r-1)->PG_L) is BROKEN for NCCL matching on a ring: the
send end (r->r+1 on PG_R) and recv end (r+1<-r, which r+1 sees as LEFT -> PG_L)
land on different communicators -> ok=False guaranteed. Implemented instead:
edge = r for peer==(r+1)%w else (r-1)%w; PG = pg_a if edge%2==0 else pg_b.
This keeps the "two ports on separate communicators" intent AND matches.

Fork criteria (with P0-1):
  B<A and B<=C -> single-PG op-matching/backpressure artifact confirmed; if
                  P0-1 64K delta_hw <=1.3 -> proceed P1/P3/P5.
  B<A but B>C  -> single-PG partial; torch proxy still non-representative for
                  small msgs -> no conclusion, rely on P5 real kernel.
  B>=A (no improve) -> single-PG not main cause; cross P0-1: 64K dhw>=1.7 ->
                  early terminate; <=1.3 -> proxy-specific unknown, defer P5.

Usage (4 ranks): python3 p0_inversion.py [--sizes 1024,4096,16384] [--iters 60]
"""
import argparse
import os
import sys
import time

import torch
import torch.distributed as dist

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from twohop_algo import twohop_allreduce, manual_ring_allreduce, NcclTransport


def _wait(w):
    if isinstance(w, (list, tuple)):
        for wi in w:
            wi.wait()
    else:
        w.wait()


class TwoPGTransport:
    """Batch step ops by ring-EDGE onto 2 process groups (edge index parity).
    Both ends of a link use the same PG -> NCCL P2P matching holds."""
    def __init__(self, rank, world, pg_a, pg_b, align=True):
        self.rank = rank
        self.world = world
        self.pg_a = pg_a
        self.pg_b = pg_b
        self.align = align
        self._pa = []
        self._pb = []
        self._t0 = 0.0
        self._last = 0.0

    def _pg(self, peer):
        if peer == (self.rank + 1) % self.world:
            edge = self.rank          # link (rank, rank+1)
        else:
            edge = (self.rank - 1) % self.world   # link (rank-1, rank)
        return self.pg_a if edge % 2 == 0 else self.pg_b

    def _bucket(self, peer):
        return "a" if self._pg(peer) is self.pg_a else "b"

    def send(self, rank, peer, buf):
        b = self._bucket(peer)
        if b == "a":
            self._pa.append(("s", buf, peer))
        else:
            self._pb.append(("s", buf, peer))
        return [(b, "s", peer)]

    def recv(self, rank, peer, buf):
        b = self._bucket(peer)
        if b == "a":
            self._pa.append(("r", buf, peer))
        else:
            self._pb.append(("r", buf, peer))
        return [(b, "r", peer)]

    def wait(self, reqs):
        # issue BOTH PG batches (concurrent on two communicators) THEN wait both.
        # NOTE: this torch's batch_isend_irecv has no `group` kwarg; group is
        # carried per-P2POp (P2POp(group=...)).
        wa = None
        wb = None
        if self._pa:
            ops = [dist.P2POp(dist.isend if k == "s" else dist.irecv, buf, peer,
                              group=self.pg_a)
                   for k, buf, peer in self._pa]
            wa = dist.batch_isend_irecv(ops)
            self._pa = []
        if self._pb:
            ops = [dist.P2POp(dist.isend if k == "s" else dist.irecv, buf, peer,
                              group=self.pg_b)
                   for k, buf, peer in self._pb]
            wb = dist.batch_isend_irecv(ops)
            self._pb = []
        if wa is not None:
            _wait(wa)
        if wb is not None:
            _wait(wb)
        torch.cuda.synchronize()

    def barrier(self):
        if self.align:
            dist.barrier()

    def sync(self):
        torch.cuda.synchronize()

    def step_begin(self):
        if not self.align:
            return
        torch.cuda.synchronize()
        self._t0 = time.perf_counter()

    def step_end(self, name):
        if not self.align:
            return
        torch.cuda.synchronize()
        self._last = (time.perf_counter() - self._t0) * 1e6

    def last_step_us(self):
        return self._last


def bench(fn, tr, n, rank, world, iters, warmup):
    """Return (avg_us, p50_us, ok)."""
    for _ in range(warmup):
        x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
        fn(x, rank, world, tr)
    torch.cuda.synchronize()
    dist.barrier()
    ts = []
    for _ in range(iters):
        x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
        torch.cuda.synchronize()
        s = time.perf_counter()
        fn(x, rank, world, tr)
        torch.cuda.synchronize()
        ts.append((time.perf_counter() - s) * 1e6)
    ts.sort()
    avg = sum(ts) / len(ts)
    p50 = ts[len(ts) // 2]
    # correctness (fresh fill, single shot)
    x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
    fn(x, rank, world, tr)
    torch.cuda.synchronize()
    ok = bool(torch.all(x == float(sum(range(world)))).item())
    return avg, p50, ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="1024,4096,16384")
    ap.add_argument("--iters", type=int, default=60)
    args = ap.parse_args()
    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    iters = max(1, args.iters)
    warmup = 15

    torch.cuda.set_device(0)
    dist.init_process_group(backend="nccl", device_id=torch.cuda.current_device())
    rank = dist.get_rank()
    world = dist.get_world_size()
    torch.cuda.synchronize()
    dist.barrier()
    if world != 4:
        raise SystemExit(f"need world=4, got {world}")

    pg_a = dist.new_group(ranks=list(range(world)))
    pg_b = dist.new_group(ranks=list(range(world)))
    # prime both new PGs + default PG before timing (avoid connection-setup pollution)
    primed = torch.full((1024,), float(rank), dtype=torch.float32, device="cuda")
    for _ in range(5):
        dist.all_reduce(primed)
        dist.all_reduce(primed, group=pg_a)
        dist.all_reduce(primed, group=pg_b)
    torch.cuda.synchronize()
    dist.barrier()

    if rank == 0:
        print(f"# P0-2 inversion probe  world={world} sizes={sizes} iters={iters}", flush=True)
        print("# mode,algo,size,avg_us,p50_us,ok", flush=True)

    for nb in sizes:
        n = nb // 4
        for algo_name, fn in [("2hop", twohop_allreduce), ("ring", manual_ring_allreduce)]:
            # A) single PG nobar
            trA = NcclTransport(rank, align=False)
            aA, pA, okA = bench(fn, trA, n, rank, world, iters, warmup)
            # B) two PG (edge parity) nobar
            trB = TwoPGTransport(rank, world, pg_a, pg_b, align=False)
            aB, pB, okB = bench(fn, trB, n, rank, world, iters, warmup)
            # C) single PG aligned (reference)
            trC = NcclTransport(rank, align=True)
            aC, pC, okC = bench(fn, trC, n, rank, world, iters, warmup)
            if rank == 0:
                print(f"A_singlePG_nobar,{algo_name},{nb},{aA:.1f},{pA:.1f},{okA}", flush=True)
                print(f"B_twoPG_nobar,{algo_name},{nb},{aB:.1f},{pB:.1f},{okB}", flush=True)
                print(f"C_singlePG_aligned,{algo_name},{nb},{aC:.1f},{pC:.1f},{okC}", flush=True)
                inv = "INVERSION" if aA > aC else "normal"
                print(f"# {algo_name}@{nb}: A_vs_C={aA/aC if aC else 0:.2f}({inv}) "
                      f"B_vs_A={aB/aA if aA else 0:.2f} B_vs_C={aB/aC if aC else 0:.2f} "
                      f"B_ok={okB}", flush=True)
        dist.barrier()

    if rank == 0:
        print("===P0_END===", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
