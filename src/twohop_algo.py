"""2-hop allreduce simulation + manual ring — algorithm core (S1 sentinel).

Serves the SAME algorithm code to:
  1) single-node CPU mock (MockTransport, no GPU) — logic correctness
  2) multi-node GPU bench (NcclTransport) — latency L' vs L

Data layout: each rank holds x as a (nchunks, chunk) tensor where
  nchunks = world (=4), chunk = n_elements/world.
After twohop_allreduce / manual_ring_allreduce, x[0..nchunks-1] all equal the
fully-reduced chunks (concat = allreduce result).

2-hop schedule (4 network steps; steps 1 & 3 are bilateral/concurrent on 2 edges):
  RS phase:
    Step 1 (bilateral): rank r
      sends right [c_{r+1}, c_{r+2}] (2 chunks, packed) ; sends left c_{r-1} (1 chunk)
      recv from right: c_r ; recv from left: [c_r, c_{r+1}]
      reduce: x[r] += recv_right_c_r + recv_left_c_r
      carry = recv_left_c_{r+1}   (= R_{r-1} contribution for chunk r+1)
    Step 2 (forward): rank r
      sends carry (c_{r+1}) -> right (rank r+1)
      recv from left (rank r-1): its carry (= R_{r-2} c_r)
      reduce: x[r] += recv_forward   -> x[r] is now FULLY reduced
  AG phase (reverse):
    Step 3 (bilateral): rank r sends fully-reduced c_r -> right AND left
      recv from right: c_{r+1}* ; recv from left: c_{r-1}*
      place into x[r+1], x[r-1] ; keep fwd = c_{r+1}* (received from right)
    Step 4 (forward): rank r sends fwd (c_{r+1}*) -> left (rank r-1)
      recv from right (rank r+1): its fwd = c_{r+2}* ; place into x[r+2]

Manual ring allreduce (6 network steps):
  RS(3): rank r sends chunk (r-s)%n to next, recv (r-s-1)%n from prev, accumulate.
         After RS, rank r holds fully-reduced chunk (r+1)%n.
  AG(3): reverse flow — rank r sends chunk (r+1+s)%n to prev, recv (r+2+s)%n from
         next. After AG, all ranks hold all 4 fully-reduced chunks.

S2 fix (2026-08-16, SRE): NcclTransport previously issued unbatched
  dist.isend/irecv one-by-one. torch eager mode SERIALIZES unbatched P2P ops on a
  process group (ProcessGroupNCCL.cpp:4130 warning), so a ring step's send+recv
  became send-then-recv: all ranks wait on their send for a matching recv that is
  never issued -> 4-way deadlock (real four-node IB hang seen in S1/S2 smoke).
  Fix: batch all send/recv of a step into ONE dist.batch_isend_irecv call so the
  ops enqueue concurrently. Mock transport unchanged (mailbox has no such issue).
"""
import time
import torch
import torch.distributed as dist


def twohop_allreduce(x, rank, world, tr, step_times=None, tag="2hop"):
    """In-place 4-step 2-hop allreduce. x: (nchunks, chunk) on this rank."""
    nch = world
    right = (rank + 1) % world
    left = (rank - 1) % world
    recv_right_c = torch.empty_like(x[rank % nch])
    recv_left_2 = torch.empty(2 * x[rank % nch].numel(), dtype=x.dtype, device=x.device)
    carry = torch.empty_like(x[(rank + 1) % nch])

    # ---------------- RS step 1 (bilateral) ----------------
    tr.step_begin()
    sr = torch.cat([x[(rank + 1) % nch].clone().reshape(-1),
                    x[(rank + 2) % nch].clone().reshape(-1)])
    sl = x[(rank - 1) % nch].clone().reshape(-1)
    reqs = []
    reqs += tr.send(rank, right, sr)
    reqs += tr.send(rank, left, sl)
    reqs += tr.recv(rank, right, recv_right_c.reshape(-1))
    reqs += tr.recv(rank, left, recv_left_2)
    tr.wait(reqs)
    tr.barrier(); tr.sync()
    tr.step_end(tag + ".rs1")
    if step_times is not None:
        step_times.append(tr.last_step_us())

    x[rank % nch] += recv_right_c
    x[rank % nch] += recv_left_2[: x[rank % nch].numel()].reshape(x[rank % nch].shape)
    carry.copy_(recv_left_2[x[rank % nch].numel():].reshape(carry.shape))

    # ---------------- RS step 2 (forward) ----------------
    tr.step_begin()
    recv_fwd = torch.empty_like(x[rank % nch])
    reqs = tr.send(rank, right, carry.reshape(-1))
    reqs += tr.recv(rank, left, recv_fwd.reshape(-1))
    tr.wait(reqs)
    tr.barrier(); tr.sync()
    tr.step_end(tag + ".rs2")
    if step_times is not None:
        step_times.append(tr.last_step_us())
    x[rank % nch] += recv_fwd

    # ---------------- AG step 3 (bilateral) ----------------
    tr.step_begin()
    mine = x[rank % nch].clone().reshape(-1)      # fully-reduced chunk r
    recv_from_right = torch.empty_like(mine)     # c_{r+1}*
    recv_from_left = torch.empty_like(mine)      # c_{r-1}*
    reqs = []
    reqs += tr.send(rank, right, mine)
    reqs += tr.send(rank, left, mine)
    reqs += tr.recv(rank, right, recv_from_right)
    reqs += tr.recv(rank, left, recv_from_left)
    tr.wait(reqs)
    tr.barrier(); tr.sync()
    tr.step_end(tag + ".ag1")
    if step_times is not None:
        step_times.append(tr.last_step_us())
    x[(rank + 1) % nch].copy_(recv_from_right.reshape(x[(rank + 1) % nch].shape))
    x[(rank - 1) % nch].copy_(recv_from_left.reshape(x[(rank - 1) % nch].shape))
    fwd = recv_from_right.clone()                # c_{r+1}* to forward left in step 4

    # ---------------- AG step 4 (forward) ----------------
    tr.step_begin()
    recv_c_rplus2 = torch.empty_like(mine)       # c_{r+2}* from right
    reqs = tr.send(rank, left, fwd)              # send c_{r+1}* to left
    reqs += tr.recv(rank, right, recv_c_rplus2)
    tr.wait(reqs)
    tr.barrier(); tr.sync()
    tr.step_end(tag + ".ag2")
    if step_times is not None:
        step_times.append(tr.last_step_us())
    x[(rank + 2) % nch].copy_(recv_c_rplus2.reshape(x[(rank + 2) % nch].shape))
    return x


def manual_ring_allreduce(x, rank, world, tr, step_times=None, tag="ring"):
    """Canonical ring allreduce via send/recv: RS(3) + AG(3) = 6 steps."""
    nch = world
    next_r = (rank + 1) % world
    prev_r = (rank - 1) % world
    chunk = x[rank % nch].numel()

    # -------- RS: 3 steps --------
    recv_buf = torch.empty(chunk, dtype=x.dtype, device=x.device)
    for s in range(world - 1):
        send_chunk = (rank - s) % nch
        recv_chunk = (rank - s - 1) % nch
        tr.step_begin()
        to_send = x[send_chunk].clone().reshape(-1)
        reqs = tr.send(rank, next_r, to_send)
        reqs += tr.recv(rank, prev_r, recv_buf.reshape(-1))
        tr.wait(reqs)
        tr.barrier(); tr.sync()
        tr.step_end(tag + f".rs{s+1}")
        if step_times is not None:
            step_times.append(tr.last_step_us())
        x[recv_chunk] += recv_buf

    # -------- AG: 3 steps (reverse flow) --------
    for s in range(world - 1):
        send_chunk = (rank + 1 + s) % nch
        recv_chunk = (rank + 2 + s) % nch
        tr.step_begin()
        to_send = x[send_chunk].clone().reshape(-1)
        recv_buf2 = torch.empty_like(to_send)
        reqs = tr.send(rank, prev_r, to_send)
        reqs += tr.recv(rank, next_r, recv_buf2)
        tr.wait(reqs)
        tr.barrier(); tr.sync()
        tr.step_end(tag + f".ag{s+1}")
        if step_times is not None:
            step_times.append(tr.last_step_us())
        x[recv_chunk].copy_(recv_buf2.reshape(x[recv_chunk].shape))
    return x


def pairwise_exchange_allreduce(x, rank, world, tr, step_times=None, tag="pair"):
    """2-step pairwise full-exchange allreduce (team-lead pairing):
    step1 pairs (0,1),(2,3); step2 pairs (1,2),(3,0). Each pair exchanges the
    FULL vector and reduces. 2 network steps, each on 2 disjoint edges concurrently.
    Data volume = 2S/rank (vs ring 1.5S) — an aggressive lower-bound datapoint."""
    nch = world
    xf = x.reshape(-1).clone()
    recv = torch.empty_like(xf)
    for s in range(2):
        if s == 0:
            partner = rank ^ 1                       # pairs (0,1),(2,3)
        else:
            partner = (rank - 1) if rank % 2 == 0 else (rank + 1)  # pairs (1,2),(3,0)
            partner %= world
        tr.step_begin()
        reqs = tr.send(rank, partner, xf)
        reqs += tr.recv(rank, partner, recv)
        tr.wait(reqs)
        tr.barrier(); tr.sync()
        tr.step_end(tag + f".{s+1}")
        if step_times is not None:
            step_times.append(tr.last_step_us())
        xf += recv
    x.copy_(xf.reshape(x.shape))
    return x


class MockTransport:
    """Single-process mailbox transport — validates algorithm logic on CPU."""
    def __init__(self, world):
        self.world = world
        self.mailbox = {}
        self.t_last = 0.0

    def send(self, rank, peer, buf):
        self.mailbox.setdefault(peer, []).append(buf.detach().clone())
        return [("s", peer)]

    def recv(self, rank, peer, buf):
        q = self.mailbox.get(rank)
        assert q, f"rank {rank}: no mail from {peer}"
        buf.copy_(q.pop(0))
        return [("r", peer)]

    def wait(self, reqs):
        return

    def barrier(self):
        return

    def sync(self):
        return

    def step_begin(self):
        return

    def step_end(self, name):
        return

    def last_step_us(self):
        return 0.0


class NcclTransport:
    """torch.distributed P2P transport for the multi-node GPU bench.

    S2 fix: ALL send/recv ops of a step are buffered and flushed in one
    dist.batch_isend_irecv(...) call, so they enqueue CONCURRENTLY on the NCCL
    process group. Unbatched dist.isend/irecv are SERIALIZED by torch eager mode
    (ProcessGroupNCCL.cpp:4130 warning), which deadlocks ring/2-hop step patterns
    where each rank's send waits for a peer recv that is issued only after wait().

    align=True inserts dist.barrier() at each step boundary (clean per-step
    timing); align=False measures the raw pipelined total (no inter-step barrier).
    """
    def __init__(self, rank, align=True):
        self.rank = rank
        self.align = align
        self._t0 = 0.0
        self._last = 0.0
        self._pending = []          # (kind, buf, peer) buffered for batch flush

    def send(self, rank, peer, buf):
        self._pending.append(("s", buf, peer))
        return [("s", buf, peer)]

    def recv(self, rank, peer, buf):
        self._pending.append(("r", buf, peer))
        return [("r", buf, peer)]

    def wait(self, reqs):
        if self._pending:
            ops = []
            for kind, buf, peer in self._pending:
                if kind == "s":
                    ops.append(dist.P2POp(dist.isend, buf, peer))
                else:
                    ops.append(dist.P2POp(dist.irecv, buf, peer))
            if ops:
                w = dist.batch_isend_irecv(ops)
                # some torch builds return a single Work, others a list of Works
                if isinstance(w, (list, tuple)):
                    for wi in w:
                        wi.wait()
                else:
                    w.wait()
            self._pending = []
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


def verify_allreduce_torch(fn, rank, world, n_elems, align=True):
    """Run fn once on real nccl transport; return (ok, elapsed_us, per_step)."""
    tr = NcclTransport(rank, align=align)
    x = torch.full((world, n_elems // world), float(rank), dtype=torch.float32, device="cuda")
    steps = [] if align else None
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    fn(x, rank, world, tr, step_times=steps)
    torch.cuda.synchronize()
    el = (time.perf_counter() - t0) * 1e6
    expect = sum(float(r) for r in range(world))
    ok = bool(torch.all(x == expect).item())
    return ok, el, steps
