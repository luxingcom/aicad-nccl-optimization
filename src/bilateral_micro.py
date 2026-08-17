#!/usr/bin/env python3
"""V2b hardware microbenchmark: bilateral concurrent send on GB10 two ports.

Q: does sending S/4 to RIGHT and S/4 to LEFT simultaneously achieve true port
concurrency on the GB10 dual-NIC ring topology?
  t_right : send S/4 to right neighbor only (+ recv S/4 from left)   [single edge]
  t_left  : send S/4 to left neighbor only  (+ recv S/4 from right)  [single edge]
  t_both  : send S/4 to right AND S/4 to left simultaneously
           (+ recv S/4 from both)                                     [bilateral]
  delta_hw = t_both / max(t_right, t_left)
Interpretation (architect plan 2.2/V2b):
  <=1.3 true port concurrency (bilateral benefit holds)
  1.3-1.7 partial contention (S3 needs per-port scheduling)
  >=1.7 shared-bottleneck serialization (bilateral assumption breaks)

Sizes: 65536 / 262144 / 368640.  WARMUP 15 / ITERS 200.
Usage (4 ranks, via run_2hop_bench.sh bilateral):
  python3 bilateral_micro.py [--sizes 65536,262144,368640] [--iters 200] [--json out.json]
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

DEFAULT_SIZES = [65536, 262144, 368640]
DEFAULT_WARMUP = 15
DEFAULT_ITERS = 200
BLOCK_TIMEOUT = 300
HB_INTERVAL = 10
LIB_PATH = "/opt/nccl-ringonly/libnccl.so.2"


class BlockTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise BlockTimeout()


def batch_wait(ops):
    """dist.batch_isend_irecv may return one Work or a list of Works."""
    w = dist.batch_isend_irecv(ops)
    if isinstance(w, (list, tuple)):
        for wi in w:
            wi.wait()
    else:
        w.wait()


def lib_md5(path):
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception as e:  # noqa: BLE001
        return f"err:{e!r}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default=None, help="csv bytes")
    ap.add_argument("--iters", type=int, default=DEFAULT_ITERS)
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    sizes = ([int(s) for s in args.sizes.split(",") if s.strip()]
             if args.sizes else list(DEFAULT_SIZES))
    iters = max(1, args.iters)
    warmup = DEFAULT_WARMUP
    proto = os.environ.get("NCCL_PROTO", "auto")

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

    right = (rank + 1) % world
    left = (rank - 1) % world

    hb_cur = {"status": "init"}
    if rank == 0:
        def _hb():
            while True:
                time.sleep(HB_INTERVAL)
                print(f"# hb {time.strftime('%H:%M:%S')} {hb_cur['status']}", flush=True)
        threading.Thread(target=_hb, daemon=True).start()

    if rank == 0:
        print(f"# V2b bilateral micro start  world={world}  protocol={proto} "
              f"sizes={sizes}  iters={iters}", flush=True)
        print("# lib:", LIB_PATH, "md5=" + lib_md5(LIB_PATH), flush=True)
        print("# size,t_right_us,t_left_us,t_both_us,delta_hw,ok", flush=True)

    results = []
    for nb in sizes:
        hb_cur["status"] = f"bilateral size={nb}"
        signal.signal(signal.SIGALRM, _alarm_handler)
        signal.setitimer(signal.ITIMER_REAL, BLOCK_TIMEOUT)
        try:
            n = nb // 4          # each direction carries S/4 elements
            if rank == 0:
                print(f"# size={nb} start", flush=True)

            def measure_edge(dst, src):
                """one edge: send S/4 to dst, recv S/4 from src. Returns
                (avg_us, p50_us, ok) — recv buf must equal float(src).
                Uses batch_isend_irecv so send+recv enqueue concurrently (torch
                serializes unbatched P2P ops -> ring deadlock, see twohop_algo)."""
                src_buf = torch.full((n,), float(rank), dtype=torch.float32, device="cuda")
                recv = torch.empty_like(src_buf)
                for _ in range(warmup):
                    batch_wait([
                        dist.P2POp(dist.isend, src_buf, dst),
                        dist.P2POp(dist.irecv, recv, src)])
                torch.cuda.synchronize()
                dist.barrier()
                ts = []
                ok = True
                for _ in range(iters):
                    src_buf.fill_(float(rank))
                    recv.fill_(-1.0)
                    torch.cuda.synchronize()
                    s = time.perf_counter()
                    batch_wait([
                        dist.P2POp(dist.isend, src_buf, dst),
                        dist.P2POp(dist.irecv, recv, src)])
                    torch.cuda.synchronize()
                    ts.append((time.perf_counter() - s) * 1e6)
                    if not torch.all(recv == float(src)).item():
                        ok = False
                ts.sort()
                return sum(ts) / len(ts), ts[len(ts) // 2], ok

            # t_right: send to right, recv from left
            t_r, p_r, ok_r = measure_edge(right, left)
            # t_left: send to left, recv from right
            t_l, p_l, ok_l = measure_edge(left, right)

            # t_both: send S/4 to right AND S/4 to left simultaneously
            br = torch.full((n,), float(rank), dtype=torch.float32, device="cuda")
            bl = torch.full((n,), float(rank), dtype=torch.float32, device="cuda")
            rr = torch.empty_like(br)   # recv from right
            rl = torch.empty_like(bl)   # recv from left
            for _ in range(warmup):
                batch_wait([
                    dist.P2POp(dist.isend, br, right),
                    dist.P2POp(dist.isend, bl, left),
                    dist.P2POp(dist.irecv, rr, right),
                    dist.P2POp(dist.irecv, rl, left)])
            torch.cuda.synchronize()
            dist.barrier()
            ts_b = []
            ok_b = True
            for _ in range(iters):
                br.fill_(float(rank)); bl.fill_(float(rank))
                rr.fill_(-1.0); rl.fill_(-1.0)
                torch.cuda.synchronize()
                s = time.perf_counter()
                batch_wait([
                    dist.P2POp(dist.isend, br, right),
                    dist.P2POp(dist.isend, bl, left),
                    dist.P2POp(dist.irecv, rr, right),
                    dist.P2POp(dist.irecv, rl, left)])
                torch.cuda.synchronize()
                ts_b.append((time.perf_counter() - s) * 1e6)
                if not (torch.all(rr == float(right)).item()
                        and torch.all(rl == float(left)).item()):
                    ok_b = False
            ts_b.sort()
            t_b = sum(ts_b) / len(ts_b)
            p_b = ts_b[len(ts_b) // 2]

            ok = ok_r and ok_l and ok_b
            delta = t_b / max(t_r, t_l) if max(t_r, t_l) > 0 else float("nan")
            if rank == 0:
                print(f"{nb},{t_r:.1f},{t_l:.1f},{t_b:.1f},{delta:.3f},{ok}", flush=True)
                print(f"# size={nb} p50: t_right={p_r:.1f} t_left={p_l:.1f} t_both={p_b:.1f}", flush=True)
                print(f"# size={nb} done ok={ok}", flush=True)
            results.append({"size": nb, "t_right_us": t_r, "t_left_us": t_l,
                            "t_both_us": t_b, "delta_hw": delta,
                            "p50_right": p_r, "p50_left": p_l, "p50_both": p_b,
                            "ok": ok})
        except BlockTimeout:
            if rank == 0:
                print(f"BLOCK_TIMEOUT size={nb} proto={proto}", flush=True)
            results.append({"size": nb, "t_right_us": float("nan"),
                            "t_left_us": float("nan"), "t_both_us": float("nan"),
                            "delta_hw": float("nan"), "ok": False})
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
        dist.barrier()

    if rank == 0:
        print("===SUMMARY===", flush=True)
        for r in results:
            print(f"S {r['size']:>8} t_right={r['t_right_us']:7.1f} "
                  f"t_left={r['t_left_us']:7.1f} t_both={r['t_both_us']:7.1f} "
                  f"delta_hw={r['delta_hw']:.3f} "
                  f"p50_r={r.get('p50_right',0):6.1f} p50_l={r.get('p50_left',0):6.1f} "
                  f"p50_b={r.get('p50_both',0):6.1f} ok={r['ok']}", flush=True)
        if args.json:
            payload = {
                "meta": {
                    "script": "bilateral_micro.py", "phase": "S2/V2b",
                    "protocol": proto, "sizes": sizes, "iters": iters,
                    "world": world,
                    "lib_path": LIB_PATH, "lib_md5": lib_md5(LIB_PATH),
                },
                "results": results,
            }
            with open(args.json, "w") as f:
                json.dump(payload, f, indent=2, default=str)
            print(f"# json written {args.json}", flush=True)
        print("===END===", flush=True)

    dist.destroy_process_group()
    all_ok = all(r["ok"] for r in results)
    sys.exit(0 if all_ok else 2)


if __name__ == "__main__":
    main()
