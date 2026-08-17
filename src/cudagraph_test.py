#!/usr/bin/env python3
"""S2 item: CUDA graph compatibility pre-validation for 2-hop bilateral comm.

Tests whether 2-hop-style concurrent bilateral communication is capturable &
replayable in CUDA graphs (the #1 risk for the 2-hop kernel in production where
vLLM captures 64 graph sizes).

  Test A (batch scaling)  : graph of B sequential full-PG all_reduces
  Test B (bilateral)      : graph of B concurrent dual-channel all_reduces on 2
                            process groups + 2 CUDA streams — 2-hop bilateral proxy
  Test C (64-batch pool)  : capture 64 graphs (vLLM full capture count)
  Test D (2-hop capture)  : capture twohop_allreduce (NcclTransport + isend/irecv)
                            into a CUDA graph — INFORMATIONAL (proxy semantics
                            differ from real NCCL kernel; failure ≠ kernel fail)

S2 additions: heartbeat + per-B watchdog (BLOCK_TIMEOUT), --protocol/--json CLI.
Usage (4 ranks):
  python3 cudagraph_test.py [--protocol auto] [--json out.json]
"""
import argparse
import hashlib
import json
import os
import signal
import sys
import threading
import time

import torch
import torch.distributed as dist

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from twohop_algo import NcclTransport, twohop_allreduce

BATCHES = [1, 8, 16, 32, 64]
N_ELEMS = 256          # 1KB float32 per allreduce buffer
K_REPLAY = 20
EAGER_ITERS = 50
BLOCK_TIMEOUT = 300
HB_INTERVAL = 10
LIB_PATH = "/opt/nccl-ringonly/libnccl.so.2"


class BlockTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise BlockTimeout()


def lib_md5(path):
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception as e:  # noqa: BLE001
        return f"err:{e!r}"


def timed(fn):
    torch.cuda.synchronize()
    s = time.perf_counter()
    fn()
    torch.cuda.synchronize()
    return (time.perf_counter() - s) * 1e6


def timed_avg(fn, iters):
    ts = []
    for _ in range(iters):
        ts.append(timed(fn))
    ts.sort()
    return sum(ts) / len(ts), ts[-1]  # avg, max(spike)


def fill_bufs(bufs, rank):
    for b in bufs:
        b.fill_(float(rank))


def check_bufs(bufs, expect):
    for b in bufs:
        if not torch.all(b == expect).item():
            return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--protocol", default="auto", choices=["auto", "LL", "Simple"])
    ap.add_argument("--json", default=None)
    args = ap.parse_args()
    if args.protocol != "auto":
        os.environ["NCCL_PROTO"] = args.protocol
    proto = os.environ.get("NCCL_PROTO", "auto")

    # S1 deadlock fix: device_id init avoids lazy 2-rank P2P domains.
    torch.cuda.set_device(0)
    dist.init_process_group(backend="nccl", device_id=torch.cuda.current_device())
    rank = dist.get_rank()
    world = dist.get_world_size()
    torch.cuda.synchronize()
    dist.barrier()
    expect = float(sum(range(world)))

    hb_cur = {"status": "init"}
    if rank == 0:
        def _hb():
            while True:
                time.sleep(HB_INTERVAL)
                print(f"# hb {time.strftime('%H:%M:%S')} {hb_cur['status']}", flush=True)
        threading.Thread(target=_hb, daemon=True).start()

    pg_a = dist.new_group(ranks=list(range(world)))
    pg_b = dist.new_group(ranks=list(range(world)))

    if rank == 0:
        print("# CUDA graph S2 test start  world=%d  N_ELEMS=%d  K_REPLAY=%d  proto=%s" %
              (world, N_ELEMS, K_REPLAY, proto), flush=True)
        print("# lib:", LIB_PATH, "md5=" + lib_md5(LIB_PATH), flush=True)

    results = []

    for B in BATCHES:
        hb_cur["status"] = f"cudagraph B={B} proto={proto}"
        signal.signal(signal.SIGALRM, _alarm_handler)
        signal.setitimer(signal.ITIMER_REAL, BLOCK_TIMEOUT)
        try:
            # ============ Test A: sequential allreduce graph ============
            bufs = [torch.full((N_ELEMS,), float(rank), dtype=torch.float32, device="cuda")
                    for _ in range(B)]
            for _ in range(10):
                for b in bufs:
                    dist.all_reduce(b)
            torch.cuda.synchronize(); dist.barrier()
            e_avg, e_max = timed_avg(lambda: [dist.all_reduce(b) for b in bufs], EAGER_ITERS)

            gA = None
            errA = ""
            try:
                gA = torch.cuda.CUDAGraph()
                with torch.cuda.graph(gA):
                    for b in bufs:
                        dist.all_reduce(b)
            except Exception as e:  # noqa: BLE001
                errA = repr(e)
            okA = False
            rep_avg = rep_max = 0.0
            if gA is not None:
                okA = True
                for _ in range(K_REPLAY):
                    fill_bufs(bufs, rank)
                    gA.replay()
                    torch.cuda.synchronize()
                    if not check_bufs(bufs, expect):
                        okA = False
                        break
                rep_avg, rep_max = timed_avg(lambda: gA.replay(), K_REPLAY)

            # ============ Test B: concurrent dual-channel graph ============
            bufs_a = [torch.full((N_ELEMS,), float(rank), dtype=torch.float32, device="cuda")
                      for _ in range(B)]
            bufs_b = [torch.full((N_ELEMS,), float(rank), dtype=torch.float32, device="cuda")
                      for _ in range(B)]
            s2 = torch.cuda.Stream()
            for _ in range(10):
                for i in range(B):
                    dist.all_reduce(bufs_a[i], group=pg_a)
                    with torch.cuda.stream(s2):
                        dist.all_reduce(bufs_b[i], group=pg_b)
            torch.cuda.synchronize(); dist.barrier()

            def run_concurrent():
                for i in range(B):
                    dist.all_reduce(bufs_a[i], group=pg_a)
                    with torch.cuda.stream(s2):
                        dist.all_reduce(bufs_b[i], group=pg_b)

            eB_avg, eB_max = timed_avg(run_concurrent, EAGER_ITERS)

            gB = None
            errB = ""
            try:
                gB = torch.cuda.CUDAGraph()
                with torch.cuda.graph(gB):
                    for i in range(B):
                        dist.all_reduce(bufs_a[i], group=pg_a)
                        with torch.cuda.stream(s2):
                            dist.all_reduce(bufs_b[i], group=pg_b)
            except Exception as e:  # noqa: BLE001
                errB = repr(e)
            okB = False
            repB_avg = repB_max = 0.0
            if gB is not None:
                okB = True
                for _ in range(K_REPLAY):
                    fill_bufs(bufs_a, rank)
                    fill_bufs(bufs_b, rank)
                    gB.replay()
                    torch.cuda.synchronize()
                    if not (check_bufs(bufs_a, expect) and check_bufs(bufs_b, expect)):
                        okB = False
                        break
                repB_avg, repB_max = timed_avg(lambda: gB.replay(), K_REPLAY)

            if rank == 0:
                print(f"B={B:>3} A: cap={gA is not None} ok={okA} "
                      f"eager={e_avg:7.1f}us rep={rep_avg:7.1f}us max={rep_max:7.1f} "
                      f"err={errA!r} | "
                      f"B: cap={gB is not None} ok={okB} "
                      f"eager={eB_avg:7.1f}us rep={repB_avg:7.1f}us max={repB_max:7.1f} "
                      f"err={errB!r}", flush=True)
            dist.barrier()
            results.append({"B": B, "A": {"cap": gA is not None, "ok": okA,
                                          "rep_avg_us": rep_avg, "rep_max_us": rep_max,
                                          "err": errA},
                            "B_test": {"cap": gB is not None, "ok": okB,
                                       "rep_avg_us": repB_avg, "rep_max_us": repB_max,
                                       "err": errB}})
        except BlockTimeout:
            if rank == 0:
                print(f"BLOCK_TIMEOUT B={B} proto={proto}", flush=True)
            results.append({"B": B, "timeout": True})
            dist.barrier()
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)

    # ============ Test C: 64-batch capture pool (vLLM full capture) ============
    if rank == 0:
        print("# Test C: capture 64 graphs (B=8 each), spike check", flush=True)
    hb_cur["status"] = "cudagraph TestC 64-pool"
    signal.signal(signal.SIGALRM, _alarm_handler)
    signal.setitimer(signal.ITIMER_REAL, BLOCK_TIMEOUT)
    pool = torch.cuda.graph_pool_handle() if hasattr(torch.cuda, "graph_pool_handle") else None
    graphs = []
    cap_ok = True
    cap_bufs = [[torch.full((N_ELEMS,), float(rank), dtype=torch.float32, device="cuda")
                 for _ in range(8)] for _ in range(64)]
    for _ in range(5):
        for grp in cap_bufs:
            for b in grp:
                dist.all_reduce(b)
    torch.cuda.synchronize(); dist.barrier()
    try:
        for gi in range(64):
            g = torch.cuda.CUDAGraph()
            with torch.cuda.graph(g, pool=pool):
                for b in cap_bufs[gi]:
                    dist.all_reduce(b)
            graphs.append(g)
    except BlockTimeout:
        cap_ok = False
        if rank == 0:
            print("BLOCK_TIMEOUT TestC", flush=True)
    except Exception as e:  # noqa: BLE001
        cap_ok = False
        if rank == 0:
            print(f"  capture {gi} failed: {e!r}", flush=True)
    repC_avg = repC_max = 0.0
    okC = cap_ok and len(graphs) == 64
    if okC:
        ts = []
        for _ in range(10):
            for grp in cap_bufs:
                fill_bufs(grp, rank)
            torch.cuda.synchronize()
            s = time.perf_counter()
            for g in graphs:
                g.replay()
            torch.cuda.synchronize()
            ts.append((time.perf_counter() - s) * 1e6)
            for grp in cap_bufs:
                if not check_bufs(grp, expect):
                    okC = False
        ts.sort()
        repC_avg = sum(ts) / len(ts)
        repC_max = ts[-1]
        if rank == 0:
            print(f"  captured={len(graphs)}/64 ok={okC} "
                  f"replay_64graphs_avg={repC_avg:.1f}us max={repC_max:.1f}us "
                  f"per_op={(repC_avg / (64 * 8)):.2f}us", flush=True)
    elif rank == 0:
        print(f"  captured={len(graphs)}/64 cap_ok={cap_ok} okC={okC}", flush=True)
    signal.setitimer(signal.ITIMER_REAL, 0)
    dist.barrier()

    # ============ Test D: 2-hop capture (informational) ============
    testD = {"captured": False, "ok": False, "err": "", "rep_avg_us": 0.0, "rep_max_us": 0.0}
    if rank == 0:
        print("# Test D: capture twohop_allreduce (informational)", flush=True)
    hb_cur["status"] = "cudagraph TestD 2-hop capture"
    signal.signal(signal.SIGALRM, _alarm_handler)
    signal.setitimer(signal.ITIMER_REAL, BLOCK_TIMEOUT)
    try:
        tr = NcclTransport(rank, align=False)
        x = torch.full((world, 64), float(rank), dtype=torch.float32, device="cuda")
        for _ in range(5):
            twohop_allreduce(x, rank, world, tr)
        torch.cuda.synchronize(); dist.barrier()
        gD = torch.cuda.CUDAGraph()
        with torch.cuda.graph(gD):
            twohop_allreduce(x, rank, world, tr)
        testD["captured"] = True
        # replay correctness
        okD = True
        for _ in range(K_REPLAY):
            x.fill_(float(rank))
            gD.replay()
            torch.cuda.synchronize()
            if not torch.all(x == float(sum(range(world)))).item():
                okD = False
                break
        testD["ok"] = okD
        repD_avg, repD_max = timed_avg(lambda: gD.replay(), K_REPLAY)
        testD["rep_avg_us"] = repD_avg
        testD["rep_max_us"] = repD_max
        if rank == 0:
            print(f"TestD: captured=T ok={okD} rep_avg={repD_avg:.1f}us max={repD_max:.1f}us",
                  flush=True)
    except BlockTimeout:
        testD["err"] = "BLOCK_TIMEOUT"
        if rank == 0:
            print("TestD: BLOCK_TIMEOUT", flush=True)
    except Exception as e:  # noqa: BLE001
        testD["err"] = repr(e)
        if rank == 0:
            print(f"TestD: captured=F err={e!r} (info only)", flush=True)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    # resync after Test D (best-effort; align=False 2-hop has no internal barrier)
    dist.barrier()

    if rank == 0:
        print("===SUMMARY===", flush=True)
        for r in results:
            if "timeout" in r:
                print(f"B {r['B']:>3} TIMEOUT", flush=True)
                continue
            a = r["A"]; bt = r["B_test"]
            print(f"B {r['B']:>3} capA={a['cap']} okA={a['ok']} repA={a['rep_avg_us']:7.1f}us "
                  f"maxA={a['rep_max_us']:7.1f} capB={bt['cap']} okB={bt['ok']} "
                  f"repB={bt['rep_avg_us']:7.1f}us maxB={bt['rep_max_us']:7.1f}", flush=True)
        print(f"testC: captured={len(graphs)}/64 ok={okC} avg={repC_avg:.1f}us "
              f"max={repC_max:.1f}us", flush=True)
        print(f"testD: captured={testD['captured']} ok={testD['ok']} "
              f"rep_avg={testD['rep_avg_us']:.1f}us max={testD['rep_max_us']:.1f} "
              f"err={testD['err']!r} (info only)", flush=True)
        if args.json:
            payload = {
                "meta": {"script": "cudagraph_test.py", "phase": "S2/V3",
                         "protocol": proto, "world": world,
                         "lib_path": LIB_PATH, "lib_md5": lib_md5(LIB_PATH)},
                "batches": results,
                "testC": {"captured": len(graphs), "ok": okC,
                          "rep_avg_us": repC_avg, "rep_max_us": repC_max},
                "testD": testD,
            }
            with open(args.json, "w") as f:
                json.dump(payload, f, indent=2, default=str)
            print(f"# json written {args.json}", flush=True)
        print("===END===", flush=True)

    dist.destroy_process_group()
    sys.exit(0)


if __name__ == "__main__":
    main()
