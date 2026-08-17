#!/usr/bin/env python3
"""S2 bench: ring(real) vs manual ring(6-step) vs 2-hop sim(4-step).

Per size measures:
  - ring_real  : torch.distributed.all_reduce (production path, env NCCL_PROTO)
  - ring_manual: 6-step send/recv ring (per-step breakdown)
  - twohop     : 4-step 2-hop send/recv sim (per-step breakdown)
  - pair       : 2-step pairwise full-exchange (aggressive lower-bound)
  - twohop_nobar: pipelined 2-hop total (no inter-step barrier)

S2 additions (architect plan 4.2):
  - CLI --protocol auto|LL|Simple / --sizes csv / --iters N / --json out.json
  - per-step annotated labels (rs1_bilateral / rs2_forward / ag1_bilateral / ag2_forward)
  - per-size watchdog (BLOCK_TIMEOUT) + rank0 heartbeat
  - SUMMARY: ratio_h / ratio_m / delta_fwd + V2a delta_bi_rs / delta_bi_ag

Usage (4 ranks, via run_2hop_bench.sh):
  python3 twohop_bench.py [--protocol auto] [--sizes 1024,4096,...]
                          [--iters 60] [--json out.json]
env: MASTER_ADDR/MASTER_PORT/WORLD_SIZE/RANK; NCCL_ALGO/RING.
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
from twohop_algo import (NcclTransport, twohop_allreduce, manual_ring_allreduce,
                         pairwise_exchange_allreduce)

DEFAULT_SIZES = [1024, 4096, 16384, 65536, 262144, 368640, 524288, 1048576]
DEFAULT_WARMUP = 15
DEFAULT_ITERS = 60
BLOCK_TIMEOUT = 300          # per size-block watchdog (seconds)
HB_INTERVAL = 10             # rank0 heartbeat (seconds)
LIB_PATH = "/opt/nccl-ringonly/libnccl.so.2"

STEP_LABELS = {
    "twohop": ["rs1_bilateral", "rs2_forward", "ag1_bilateral", "ag2_forward"],
    "ring":   ["rs1", "rs2", "rs3", "ag1", "ag2", "ag3"],
    "pair":   ["s1", "s2"],
}


class BlockTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise BlockTimeout()


def timed(fn, iters):
    """Return (avg_us, p50_us) over iters of a warm fn, with sync."""
    ts = []
    for _ in range(iters):
        torch.cuda.synchronize()
        s = time.perf_counter()
        fn()
        torch.cuda.synchronize()
        ts.append((time.perf_counter() - s) * 1e6)
    ts.sort()
    return sum(ts) / len(ts), ts[len(ts) // 2]


def bench_ring_real(n, iters, warmup):
    t = torch.full((n,), float(dist.get_rank()), dtype=torch.float32, device="cuda")
    for _ in range(warmup):
        dist.all_reduce(t)
    torch.cuda.synchronize()
    dist.barrier()
    avg, p50 = timed(lambda: dist.all_reduce(t), iters)
    t.fill_(float(dist.get_rank()))
    torch.cuda.synchronize()
    dist.all_reduce(t)
    torch.cuda.synchronize()
    ok = bool(torch.all(t == float(sum(range(dist.get_world_size())))).item())
    return avg, p50, ok


def bench_algo(fn, n, rank, world, iters, warmup, align=True):
    """bench manual algorithm; returns (total_avg, p50, per_step_avg_list, ok)."""
    tr = NcclTransport(rank, align=align)
    for _ in range(warmup):
        x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
        fn(x, rank, world, tr)
    torch.cuda.synchronize()
    dist.barrier()
    total_ts = []
    per_step_sum = None
    for _ in range(iters):
        x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
        steps = [] if align else None
        torch.cuda.synchronize()
        s = time.perf_counter()
        fn(x, rank, world, tr, step_times=steps)
        torch.cuda.synchronize()
        total_ts.append((time.perf_counter() - s) * 1e6)
        if steps is not None:
            if per_step_sum is None:
                per_step_sum = steps
            else:
                per_step_sum = [a + b for a, b in zip(per_step_sum, steps)]
    x = torch.full((world, n // world), float(rank), dtype=torch.float32, device="cuda")
    fn(x, rank, world, tr)
    torch.cuda.synchronize()
    ok = bool(torch.all(x == float(sum(range(world)))).item())
    total_ts.sort()
    per_step = None
    if per_step_sum is not None:
        per_step = [v / iters for v in per_step_sum]
    return sum(total_ts) / len(total_ts), total_ts[len(total_ts) // 2], per_step, ok


def bench_nobar(fn, n, rank, world, iters, warmup):
    """Pipelined total (align=False): no inter-step barrier, no per-step timing.
    Closest proxy to the real kernel's wall-clock for the same step structure."""
    tr = NcclTransport(rank, align=False)
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
    return sum(ts) / len(ts), ts[len(ts) // 2]


def lib_md5(path):
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception as e:  # noqa: BLE001
        return f"err:{e!r}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--protocol", default="auto", choices=["auto", "LL", "Simple"])
    ap.add_argument("--sizes", default=None, help="csv bytes, e.g. 1024,4096")
    ap.add_argument("--iters", type=int, default=DEFAULT_ITERS)
    ap.add_argument("--json", default=None, help="path to write structured JSON (rank0)")
    args = ap.parse_args()

    sizes = ([int(s) for s in args.sizes.split(",") if s.strip()]
             if args.sizes else list(DEFAULT_SIZES))
    iters = max(1, args.iters)
    warmup = DEFAULT_WARMUP
    if args.protocol != "auto":
        os.environ["NCCL_PROTO"] = args.protocol
    elif "NCCL_PROTO" in os.environ and os.environ["NCCL_PROTO"]:
        # honor externally-injected NCCL_PROTO (run_2hop_bench.sh env mode)
        pass
    proto = os.environ.get("NCCL_PROTO", "auto")

    # S1 deadlock fix (kept): set device then init with device_id -> reuse the
    # main 4-rank comm domain, never lazily build 2-rank P2P domains.
    torch.cuda.set_device(0)
    dist.init_process_group(backend="nccl", device_id=torch.cuda.current_device())
    rank = dist.get_rank()
    world = dist.get_world_size()
    torch.cuda.synchronize()
    dist.barrier()
    if world != 4:
        if rank == 0:
            print(f"FATAL world must be 4, got {world}", flush=True)
        raise SystemExit(2)

    # heartbeat thread (rank0 only)
    hb_cur = {"status": "init"}
    if rank == 0:
        def _hb():
            while True:
                time.sleep(HB_INTERVAL)
                print(f"# hb {time.strftime('%H:%M:%S')} {hb_cur['status']}", flush=True)
        threading.Thread(target=_hb, daemon=True).start()

    if rank == 0:
        print(f"# S2 bench start  world={world}  protocol={proto}  sizes={sizes} "
              f"iters={iters}  warmup={warmup}", flush=True)
        print("# env:", {k: v for k, v in os.environ.items()
                         if k.startswith("NCCL") and k not in ("NCCL_DEBUG",)}, flush=True)
        print(f"# lib: {LIB_PATH} md5={lib_md5(LIB_PATH)}", flush=True)
        print("# size,ring_real_us,ring_manual_us,ring_manual_ps,2hop_us,2hop_ps,"
              "pair_us,pair_ps,2hop_nobar_us,ring_manual_nobar_us,"
              "ok_r,ok_m,ok_2,ok_p", flush=True)

    # connection priming: complete lazy NCCL connect on a plain all_reduce so the
    # first size block is not polluted by one-time connection setup.
    primed = torch.full((1024,), float(rank), dtype=torch.float32, device="cuda")
    for _ in range(5):
        dist.all_reduce(primed)
    torch.cuda.synchronize()
    dist.barrier()
    if rank == 0:
        print("# priming all_reduce done", flush=True)

    results = []
    block_timeouts = []

    for nb in sizes:
        n = nb // 4
        hb_cur["status"] = f"size={nb} proto={proto}"
        signal.signal(signal.SIGALRM, _alarm_handler)
        signal.setitimer(signal.ITIMER_REAL, BLOCK_TIMEOUT)
        try:
            if rank == 0:
                print(f"# size={nb} start proto={proto}", flush=True)
            avg_r, p50_r, ok_r = bench_ring_real(n, iters, warmup)
            avg_m, p50_m, per_m, ok_m = bench_algo(
                manual_ring_allreduce, n, rank, world, iters, warmup, align=True)
            avg_h, p50_h, per_h, ok_h = bench_algo(
                twohop_allreduce, n, rank, world, iters, warmup, align=True)
            avg_p, p50_p, per_p, ok_p = bench_algo(
                pairwise_exchange_allreduce, n, rank, world, iters, warmup, align=True)
            # no-barrier pipelined totals: 2-hop (4 steps) and manual ring (6 steps)
            avg_h_nb, p50_h_nb = bench_nobar(
                twohop_allreduce, n, rank, world, iters, warmup)
            avg_m_nb, p50_m_nb = bench_nobar(
                manual_ring_allreduce, n, rank, world, iters, warmup)
            block_ok = True
        except BlockTimeout:
            block_ok = False
            avg_r = avg_m = avg_h = avg_p = avg_h_nb = avg_m_nb = float("nan")
            p50_r = p50_m = p50_h = p50_p = p50_h_nb = p50_m_nb = float("nan")
            per_m = per_h = per_p = None
            ok_r = ok_m = ok_h = ok_p = False
            block_timeouts.append(nb)
            if rank == 0:
                print(f"BLOCK_TIMEOUT size={nb} proto={proto}", flush=True)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)

        if rank == 0:
            pm = ",".join(f"{v:.1f}" for v in per_m) if per_m else "-"
            ph = ",".join(f"{v:.1f}" for v in per_h) if per_h else "-"
            pp = ",".join(f"{v:.1f}" for v in per_p) if per_p else "-"
            print(f"{nb},{avg_r:.1f},{avg_m:.1f},{pm},{avg_h:.1f},{ph},{avg_p:.1f},{pp},"
                  f"{avg_h_nb:.1f},{avg_m_nb:.1f},{ok_r},{ok_m},{ok_h},{ok_p}", flush=True)
            print(f"# size={nb} done proto={proto} ok={block_ok}", flush=True)
        dist.barrier()
        results.append({
            "size": nb, "block_ok": block_ok,
            "ring_real_us": avg_r, "ring_real_p50": p50_r,
            "ring_manual_us": avg_m, "ring_manual_p50": p50_m,
            "ring_manual_per_step": per_m, "ring_manual_step_labels": STEP_LABELS["ring"],
            "ring_manual_nobar_us": avg_m_nb, "ring_manual_nobar_p50": p50_m_nb,
            "2hop_us": avg_h, "2hop_p50": p50_h,
            "2hop_per_step": per_h, "2hop_step_labels": STEP_LABELS["twohop"],
            "2hop_nobar_us": avg_h_nb, "2hop_nobar_p50": p50_h_nb,
            "pair_us": avg_p, "pair_p50": p50_p,
            "pair_per_step": per_p, "pair_step_labels": STEP_LABELS["pair"],
            "ok": {"ring_real": ok_r, "ring_manual": ok_m, "2hop": ok_h, "pair": ok_p},
        })

    dist.barrier()
    if rank == 0:
        print("===SUMMARY===", flush=True)
        ok_all = True
        for r in results:
            ratio_m = r["2hop_us"] / r["ring_manual_us"] if r["ring_manual_us"] else float("nan")
            ratio_h = r["2hop_us"] / r["ring_real_us"] if r["ring_real_us"] else float("nan")
            ratio_p = r["pair_us"] / r["ring_real_us"] if r["ring_real_us"] else float("nan")
            delta_fwd = float("nan")
            delta_bi_rs = delta_bi_ag = float("nan")
            if r["2hop_per_step"] and len(r["2hop_per_step"]) == 4:
                fwd_h = (r["2hop_per_step"][1] + r["2hop_per_step"][3]) / 2.0
                m_steps = r["ring_manual_per_step"]
                if m_steps and len(m_steps) >= 3:
                    delta_fwd = fwd_h / (sum(m_steps) / len(m_steps))
                delta_bi_rs = r["2hop_per_step"][0] / r["2hop_per_step"][1] \
                    if r["2hop_per_step"][1] else float("nan")
                delta_bi_ag = r["2hop_per_step"][2] / r["2hop_per_step"][3] \
                    if r["2hop_per_step"][3] else float("nan")
            r["ratio_h"] = ratio_h
            r["ratio_m"] = ratio_m
            r["delta_fwd"] = delta_fwd
            r["delta_bi_rs"] = delta_bi_rs
            r["delta_bi_ag"] = delta_bi_ag
            r["ratio_h_nb"] = (r["2hop_nobar_us"] / r["ring_real_us"]
                               if r["ring_real_us"] else float("nan"))
            r["ratio_m_nb"] = (r["2hop_nobar_us"] / r["ring_manual_nobar_us"]
                               if r["ring_manual_nobar_us"] else float("nan"))
            ok_line = r["ok"]
            if not all(ok_line.values()):
                ok_all = False
            print(f"S {r['size']:>8} ring_real={r['ring_real_us']:8.1f} "
                  f"ring_manual={r['ring_manual_us']:8.1f} 2hop={r['2hop_us']:8.1f} "
                  f"2hop_nobar={r['2hop_nobar_us']:8.1f} ringm_nobar={r['ring_manual_nobar_us']:8.1f} "
                  f"pair={r['pair_us']:8.1f} "
                  f"ratio_h={ratio_h:.3f} ratio_m={ratio_m:.3f} "
                  f"ratio_h_nb={r['ratio_h_nb']:.3f} ratio_m_nb={r['ratio_m_nb']:.3f} "
                  f"delta_fwd={delta_fwd:.3f} "
                  f"d_bi_rs={delta_bi_rs:.2f} d_bi_ag={delta_bi_ag:.2f} "
                  f"ok=({ok_line['ring_real']},{ok_line['ring_manual']},"
                  f"{ok_line['2hop']},{ok_line['pair']})", flush=True)
        print(f"SUMMARY_EXIT ok_all={ok_all} block_timeouts={block_timeouts}", flush=True)
        if args.json:
            payload = {
                "meta": {
                    "script": "twohop_bench.py", "phase": "S2",
                    "protocol": proto, "sizes": sizes, "iters": iters, "warmup": warmup,
                    "world": world,
                    "nccl_env": {k: v for k, v in os.environ.items()
                                 if k.startswith("NCCL") and k not in ("NCCL_DEBUG",)},
                    "lib_path": LIB_PATH, "lib_md5": lib_md5(LIB_PATH),
                },
                "summary_exit": ok_all,
                "block_timeouts": block_timeouts,
                "sizes": results,
            }
            with open(args.json, "w") as f:
                json.dump(payload, f, indent=2, default=str)
            print(f"# json written {args.json}", flush=True)
        print("===END===", flush=True)

    dist.destroy_process_group()
    exit_code = 0 if (all(r["ok"].values() for r in results) and not block_timeouts) else 2
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
