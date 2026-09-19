/* ar2_core.cpp — S2 引擎: verbs 双链 + TCP 星型控制面 + 协议机 + 错误模型
 * 骨架来源: proto_2round_ar.c v6 (fabric 实测验证) + spark_transport 错误范式强化 */
#include "ar2_internal.hpp"

#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <thread>

namespace ar2 {

/* CUDA 后端为弱符号: selftest 等仅链接 core+cpu 时不解析 */
Device *make_cuda_device() __attribute__((weak));

Link::~Link() {
  for (int q = 0; q < nqp; q++)
    if (qp[q]) ibv_destroy_qp(qp[q]);
  if (cq) ibv_destroy_cq(cq);
  if (mr) ibv_dereg_mr(mr);
  if (pd) ibv_dealloc_pd(pd);
  if (ctx) ibv_close_device(ctx);
}

/* ---------------- TCP 工具 (deadline 有界, OOM 整改: 无阻塞放大) ---------------- */
static bool tcp_send_all(int fd, const void *p, size_t n, int timeout_ms) {
  const char *b = (const char *)p;
  auto t0 = std::chrono::steady_clock::now();
  while (n) {
    ssize_t k = ::send(fd, b, n, MSG_NOSIGNAL);
    if (k > 0) { b += k; n -= (size_t)k; continue; }
    if (k < 0 && errno == EINTR) continue;   /* 审计修复: 信号打断不算失败 */
    if (k < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      if (std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - t0).count() > timeout_ms)
        return false;
      spin_pause();
      continue;
    }
    return false;
  }
  return true;
}
static bool tcp_recv_all(int fd, void *p, size_t n, int timeout_ms) {
  char *b = (char *)p;
  auto t0 = std::chrono::steady_clock::now();
  while (n) {
    ssize_t k = ::recv(fd, b, n, MSG_DONTWAIT);
    if (k > 0) { b += k; n -= (size_t)k; continue; }
    if (k == 0) return false;
    if (k < 0 && errno == EINTR) continue;   /* 审计修复 */
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      if (std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - t0).count() > timeout_ms)
        return false;
      spin_pause();
      continue;
    }
    return false;
  }
  return true;
}

/* 星型控制面: rank0 聚合 (proto bootstrap 模式), 会话期保持供 ABORT 中继/拆除 barrier */
static void ctrl_close(CtrlPlane &cp);
static int ctrl_connect(CtrlPlane &cp, const ar2_config &cfg) {
  if (getenv("AR2_TRACE")) fprintf(stderr, "[trace] rank%d ctrl_connect enter\n", cfg.rank);
  cp.rank = cfg.rank;
  cp.world = cfg.world;
  for (int r = 0; r < 4; r++) cp.fds[r] = -1;
  if (cfg.rank == 0) {
    int lfd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return AR2_ERR_VERBS;
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    fcntl(lfd, F_SETFL, O_NONBLOCK);   /* 审计修复: 非阻塞监听, poll/accept 无竞态 */
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)cfg.ctrl_port);
    a.sin_addr.s_addr = INADDR_ANY;
    if (::bind(lfd, (sockaddr *)&a, sizeof a) || ::listen(lfd, 8)) {
      ::close(lfd);
      return AR2_ERR_VERBS;
    }
    for (int k = 1; k < cfg.world;) {   /* 无效连接(扫描器/竞速残留)关掉继续等 */
      /* 审计修复: accept 带 deadline (poll+非阻塞), 缺员不再无限挂死; 与 worker 240×0.5s 对齐 */
      pollfd pf{};
      pf.fd = lfd;
      pf.events = POLLIN;
      int pr = ::poll(&pf, 1, cfg.timeout_ms * 24);
      if (pr <= 0) { ::close(lfd); ctrl_close(cp); return AR2_ERR_TIMEOUT; }
      sockaddr_in c{};
      socklen_t cl = sizeof c;
      int fd = ::accept(lfd, (sockaddr *)&c, &cl);
      if (fd < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        ::close(lfd); ctrl_close(cp); return AR2_ERR_VERBS;
      }
      int r = 0;   /* 高位保持 0: recv 只写 1 字节 (proto v2 教训) */
      if (!tcp_recv_all(fd, &r, 1, 30000) || r < 1 || r >= cfg.world || cp.fds[r] != -1) {
        ::close(fd);   /* 无效: 丢弃, 不占槽 */
        continue;
      }
      cp.fds[r] = fd;
      k++;
    }
    ::close(lfd);
  } else {
    if (!cfg.peer_ips[0]) return AR2_ERR_INVALID;
    int fd = -1;
    for (int t = 0; t < 240; t++) {   /* ECONNREFUSED 后 socket 即废: 每次重建 */
      fd = ::socket(AF_INET, SOCK_STREAM, 0);
      sockaddr_in a{};
      a.sin_family = AF_INET;
      a.sin_port = htons((uint16_t)cfg.ctrl_port);
      a.sin_addr.s_addr = inet_addr(cfg.peer_ips[0]);
      if (fd >= 0 && !::connect(fd, (sockaddr *)&a, sizeof a)) break;
      if (fd >= 0) ::close(fd);
      fd = -1;
      if (t == 239) return AR2_ERR_TIMEOUT;
      usleep(500 * 1000);
    }
    uint8_t r = (uint8_t)cfg.rank;
    if (!tcp_send_all(fd, &r, 1, 5000)) { ::close(fd); return AR2_ERR_VERBS; }
    cp.fds[0] = fd;
  }
  return AR2_OK;
}

static void ctrl_close(CtrlPlane &cp) {
  for (int r = 0; r < 4; r++)
    if (cp.fds[r] >= 0) { ::close(cp.fds[r]); cp.fds[r] = -1; }
}

static const uint32_t kAbortMsgMagic = 0xA2B0A2B0u;
static void ctrl_broadcast_abort(CtrlPlane &cp, int reason) {
  uint64_t msg = ((uint64_t)kAbortMsgMagic << 32) | (uint32_t)reason;
  if (cp.rank == 0) {
    for (int r = 0; r < cp.world; r++)
      if (cp.fds[r] >= 0) tcp_send_all(cp.fds[r], &msg, 8, 300);
  } else if (cp.fds[0] >= 0) {
    tcp_send_all(cp.fds[0], &msg, 8, 300);
  }
}
static bool ctrl_poll_abort(CtrlPlane &cp, int *reason = nullptr) {
  /* 审计B2-问题1 修复: 每 fd 分级缓冲凑满 8B 整帧再校验 —— 原实现 recv 到 1~7 字节
   * 即丢弃, TCP 分段会让 abort 帧永久失步 (fence 的孤立 'F' 字节被误吞是同一根因)。 */
  for (int r = 0; r < cp.world; r++) {
    if (cp.fds[r] < 0) continue;
    if (cp.alen[r] < 8) {
      ssize_t k = ::recv(cp.fds[r], cp.abuf[r] + cp.alen[r], 8 - cp.alen[r], MSG_DONTWAIT);
      if (k > 0) cp.alen[r] += (int)k;
      else if (k == 0 || (k < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
        cp.fds[r] = -1;   /* 对端关闭/硬错: 摘除该连接, 后续不再轮询 */
        continue;
      }
    }
    if (cp.alen[r] == 8) {
      uint64_t msg;
      memcpy(&msg, cp.abuf[r], 8);
      cp.alen[r] = 0;   /* 无论是否合法帧都已消费 8B; 非法帧 = 流错乱, 丢弃续读 */
      if ((uint32_t)(msg >> 32) == kAbortMsgMagic) {
        if (reason) *reason = (int)(uint32_t)msg;
        return true;
      }
    }
  }
  return false;
}

/* ---------------- V5 fence-arm 栅栏 (2026-09-04 E2E #1/#2 定谳产物) ----------------
 * 背景: vLLM 启动期 dspark speculator 的 warmup(eager 小 AR) 与 capture(原生录制) 在
 * 4 rank 间无全局栅栏, 相位错位时本端 ar2 的门铃永不到 (对端同逻辑 op 已录进 graph,
 * 延迟到 replay 才执行) → 超时/poison, 且非对称 abort 竞态可致 GPU IMA —— 事后降级
 * 无法根治 (E2E #2 rank2 降级成功但 rank0 IMA)。稳态服务是 SPMD 锁步, 分发安全。
 * 本栅栏在 "捕获期之后首个大 AR" (全 rank 同逻辑、必经 op) 处集合: 四端到齐才放行
 * 武装, 保证此后逐 op 的 ar2/原生 决策跨 rank 一致 (错误方向=安全方向=全原生)。
 * 协议 (审计A1 修复版): worker→rank0 发 'F' 1B; rank0 在【单一共享 deadline】内收齐
 * world-1 个 'F' 后回 'G' 1B, 收不齐则向已收到的 fd 广播 'N' (对称快速失败);
 * worker 等 'G'/'N' 的窗口 = kDeadlineMs×world (覆盖 rank0 收集期, 保证 rank0 成功
 * ⟹ 所有 worker 必在窗口内收到 'G' —— 旧版逐 fd 独立 10s 会产生部分武装错位)。
 * 'F'/'G'/'N' 均为完全消费的孤立字节, 不污染 8B abort 帧 (poll 侧另有分级缓冲)。 */
static int ctrl_arm_fence(CtrlPlane &cp) {
  const int kDeadlineMs = 10000;
  const uint8_t kF = 'F', kG = 'G', kN = 'N';
  if (cp.world < 2) return AR2_OK;   /* 自测单进程: 无需栅栏 */
  if (cp.rank == 0) {
    int64_t dl = now_ms() + kDeadlineMs;   /* 共享 deadline: 整个收集过程一个窗口 */
    int got = 0;
    for (int r = 1; r < cp.world && got >= 0; r++) {
      if (cp.fds[r] < 0) { got = -1; break; }
      /* 用共享剩余窗口做超时的阻塞收 (busy-wait + deadline) */
      for (;;) {
        uint8_t b = 0;
        ssize_t k = ::recv(cp.fds[r], &b, 1, MSG_DONTWAIT);
        if (k == 1 && b == kF) break;
        if (k == 1) { got = -1; break; }            /* 杂字节/帧错乱 */
        if (k == 0 || (k < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
          got = -1; break;                          /* 对端关闭/硬错 */
        }
        if (now_ms() > dl) { got = -1; break; }     /* 共享窗口耗尽 */
        spin_pause();
      }
    }
    if (got < 0) {
      for (int r = 1; r < cp.world; r++)            /* NACK: 已到齐的 worker 快速对称失败 */
        if (cp.fds[r] >= 0) tcp_send_all(cp.fds[r], &kN, 1, 300);
      return AR2_ERR_TIMEOUT;
    }
    for (int r = 1; r < cp.world; r++)
      if (!tcp_send_all(cp.fds[r], &kG, 1, 300)) return AR2_ERR_VERBS;
    return AR2_OK;
  }
  if (cp.fds[0] < 0) return AR2_ERR_VERBS;
  if (!tcp_send_all(cp.fds[0], &kF, 1, 300)) return AR2_ERR_VERBS;
  uint8_t b = 0;
  /* 窗口 = kDeadlineMs×world: 覆盖 rank0 的完整收集期 (共享 deadline + 收集裕量),
   * 消除旧版 worker 固定 10s vs rank0 串行 30s 的记账不对称 (审计A1) */
  if (!tcp_recv_all(cp.fds[0], &b, 1, kDeadlineMs * cp.world)) return AR2_ERR_TIMEOUT;
  if (b == kN) return AR2_ERR_TIMEOUT;   /* rank0 侧收集失败的 NACK */
  if (b != kG) return AR2_ERR_TIMEOUT;
  return AR2_OK;
}

/* ---------------- verbs 链路 (proto v6 骨架) ---------------- */
static ibv_context *open_dev(const char *name) {
  int n = 0;
  ibv_device **dl = ibv_get_device_list(&n);
  ibv_context *found = nullptr;
  for (int i = 0; i < n; i++)
    if (!found && name == std::string(ibv_get_device_name(dl[i])))
      found = ibv_open_device(dl[i]);
  if (dl) ibv_free_device_list(dl);   /* 审计修复: 配对释放 (opened context 仍有效) */
  return found;
}

/* QP 容量依据: max_send_wr=128 (host 每 op 每 QP 2 WR, 128 = 深度裕量而非并发需求 ——
 * engine host 阻塞语义下单 QP 在飞 WR 恒 ≤2); max_recv_wr=4 (RDMA recv 从不消耗, 对端
 * 只 write 不 send); max_inline_data=64 (8B 门铃/旗标 inline 直达, 免 DMA 信令延迟);
 * CQ 256 = nqp×WR 容量 ×2 裕量 (全部 QP 共享)。容量不回读校验属已知边界 (AUDIT-REPORT §七.3)。
 * R3: nqp 个 QP 共享 PD/CQ/MR —— 建连方按序号一一配对 (本端 qp[q] ↔ 对端 qpn[q])。 */
static int link_setup(Link *L, const char *dev, uint8_t *arena, size_t arena_sz, int nqp) {
  if (nqp < 1 || nqp > AR2_MAX_QPS) return AR2_ERR_INVALID;
  L->ctx = open_dev(dev);
  if (!L->ctx) return AR2_ERR_VERBS;
  L->pd = ibv_alloc_pd(L->ctx);
  L->cq = ibv_create_cq(L->ctx, 256, nullptr, nullptr, 0);
  L->buf = arena;
  L->buf_bytes = arena_sz;
  L->mr = ibv_reg_mr(L->pd, arena, arena_sz, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE);
  if (!L->mr || !L->cq || !L->pd) return AR2_ERR_VERBS;
  for (int q = 0; q < nqp; q++) {
    ibv_qp_init_attr qia{};
    qia.send_cq = L->cq;
    qia.recv_cq = L->cq;
    qia.qp_type = IBV_QPT_RC;
    qia.cap.max_send_wr = 128;
    qia.cap.max_recv_wr = 4;
    qia.cap.max_send_sge = 2;
    qia.cap.max_recv_sge = 1;
    qia.cap.max_inline_data = 64;
    L->qp[q] = ibv_create_qp(L->pd, &qia);
    if (!L->qp[q]) return AR2_ERR_VERBS;
  }
  L->nqp = nqp;
  return AR2_OK;
}

/* QP 参数与 PROTOCOL.md §2 互链: timeout=14 (~2.6s 重传判死, 比引擎 5s deadline 短
 * 一档让 verbs 层先报) / retry_cnt=7 (IB 规范 3.09s 上限内最长) / rnr_retry=7+min_rnr=12
 * (对端 recv 队列永不空, RNR 只是瞬态) / MTU≤4096 (CX-7 RoCE 网实测稳定档) /
 * hop_limit=64 (同机房 2 跳, 64=规范默认宽松值)。
 * R3: 同参数逐 QP 独立迁移 (INIT→RTR→RTS), qpn[q] 一一配对 —— 参数集与单 QP 期完全
 * 一致, 不因多 QP 改传输层行为。 */
static int link_connect(Link *L, const PeerInfo &peer, int gid_index) {
  ibv_port_attr pa{};
  if (ibv_query_port(L->ctx, 1, &pa)) return AR2_ERR_VERBS;
  if (peer.nqp != (uint8_t)L->nqp) return AR2_ERR_PROTOCOL;   /* 几何已在上层校验, 双保险 */
  for (int q = 0; q < L->nqp; q++) {
    ibv_qp_attr a{};
    a.qp_state = IBV_QPS_INIT;
    a.pkey_index = 0;
    a.port_num = 1;
    a.qp_access_flags = IBV_ACCESS_REMOTE_WRITE;
    if (ibv_modify_qp(L->qp[q], &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS))
      return AR2_ERR_VERBS;
    a = ibv_qp_attr{};
    a.qp_state = IBV_QPS_RTR;
    a.path_mtu = (ibv_mtu)(pa.active_mtu < IBV_MTU_4096 ? pa.active_mtu : IBV_MTU_4096);
    a.dest_qp_num = peer.qpn[q];
    a.rq_psn = 0;
    a.max_dest_rd_atomic = 1;
    a.min_rnr_timer = 12;
    a.ah_attr.is_global = 1;
    a.ah_attr.port_num = 1;
    a.ah_attr.grh.dgid = *(ibv_gid *)peer.gid;
    a.ah_attr.grh.sgid_index = (uint8_t)gid_index;
    a.ah_attr.grh.hop_limit = 64;
    if (ibv_modify_qp(L->qp[q], &a,
                      IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                          IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER))
      return AR2_ERR_VERBS;
    a = ibv_qp_attr{};
    a.qp_state = IBV_QPS_RTS;
    a.sq_psn = 0;
    a.timeout = 14;
    a.retry_cnt = 7;
    a.rnr_retry = 7;
    a.max_rd_atomic = 1;
    if (ibv_modify_qp(L->qp[q], &a,
                      IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                          IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC))
      return AR2_ERR_VERBS;
  }
  L->peer = peer;
  return AR2_OK;
}

static void fill_peer_info(Link *L, PeerInfo *pi, int rank, int dtype, uint32_t smax, int nslots,
                           int gid_index) {
  /* 审计修复: gid 查询与建连同源 (原硬编码 3, 配置非 3 时对端拿到错误 dgid) */
  if (ibv_query_gid(L->ctx, 1, gid_index, (ibv_gid *)pi->gid)) {
    memset(pi->gid, 0, sizeof pi->gid);   /* 留全零; link_connect 将因 GRH 非法而失败 */
  }
  pi->magic = 0xA2C0A2C0u;
  pi->version = AR2_VERSION;
  pi->rank = (uint16_t)rank;
  pi->dtype = (uint16_t)dtype;
  pi->smax = smax;
  pi->nslots = (uint32_t)nslots;
  for (int q = 0; q < L->nqp; q++) pi->qpn[q] = L->qp[q]->qp_num;
  pi->nqp = (uint8_t)L->nqp;
  pi->rkey = L->mr->rkey;
  pi->addr = (uint64_t)L->buf;
}

/* ---------------- 引擎 ---------------- */
struct GraphState {
  bool valid = false;
  int n = 0;
  void *bufs[AR2_MAX_LAYER_OPS] = {};
  uint32_t bytes[AR2_MAX_LAYER_OPS] = {};
};

/* M2 取证: 每 op 引擎侧时间线 (ns) + 槽数据快照; ring 32 项, engine 单线程 */
struct OpLogE { uint64_t seq; uint32_t slot; uint32_t bytes; int64_t t_prod, t_pa, t_arm, t_pb, t_done;
                uint64_t senda_first, sendb_first, recva_first, recvb_first, canary_x, canary_sA; };

struct Comm {
  ar2_config cfg{};
  Link *A = nullptr, *B = nullptr;
  CtrlPlane ctrl;
  Device *dev = nullptr;
  volatile Ar2Ctl *ctlA = nullptr, *ctlB = nullptr;
  volatile uint64_t *seq_words = nullptr;
  uint64_t seq_ = 0;
  uint64_t completed_ = 0;
  bool poisoned = false;
  int poison_reason = AR2_OK;
  bool abort_sent = false;
  GraphState graph;
  GraphState gtab[AR2_MAX_GRAPHS];   /* M2GI GI-A: vLLM 图层表 (kernel 由调用方图承载) */
  int ngraphs = 0;
  OpLogE oplog[32] = {};
  int oplog_i = 0;
  inline void log_mark(uint64_t seq, uint32_t slot, uint32_t bytes, int stage, uint64_t snap = 0,
                       uint64_t snap2 = 0) {
    if (oplog[oplog_i].seq != seq) {   /* 新 op: 环上开新条目 (引用须在推进后重绑) */
      oplog_i = (oplog_i + 1) % 32;
      OpLogE &ne = oplog[oplog_i];
      ne.seq = seq; ne.slot = slot; ne.bytes = bytes;
      ne.t_prod = ne.t_pa = ne.t_arm = ne.t_pb = ne.t_done = 0;
      ne.senda_first = ne.sendb_first = ne.recva_first = ne.recvb_first = 0;
      ne.canary_x = ne.canary_sA = 0;
    }
    OpLogE &e = oplog[oplog_i];
    int64_t t = now_ns();
    if (stage == 0) { e.t_prod = t; e.canary_x = snap; e.canary_sA = snap2; }
    else if (stage == 1) { e.t_pa = t; e.senda_first = snap; }
    else if (stage == 2) e.t_arm = t;
    else if (stage == 3) { e.t_pb = t; e.sendb_first = snap; }
    else if (stage == 4) e.t_done = t;
    else if (stage == 5) { e.recva_first = snap; }
    else if (stage == 6) { e.recvb_first = snap; }
  }
  /* 所有权转移给 wrapper (避免析构双释放) */
  void steal(Comm *o) {
    A = o->A; o->A = nullptr;
    B = o->B; o->B = nullptr;
    ctrl = o->ctrl;
    for (int r = 0; r < 4; r++) o->ctrl.fds[r] = -1;
    dev = o->dev; o->dev = nullptr;
    ctlA = o->ctlA; ctlB = o->ctlB; seq_words = o->seq_words;
    seq_ = o->seq_; completed_ = o->completed_;
    poisoned = o->poisoned; poison_reason = o->poison_reason;
    abort_sent = o->abort_sent; graph = o->graph;
    memcpy(oplog, o->oplog, sizeof oplog); oplog_i = o->oplog_i;
    cfg = o->cfg;
  }
  ~Comm() {
    /* arena 释放纪律 (审计修复): 先拆 MR (Link 析构 dereg), 再还 arena 给后端, 最后删后端 */
    uint8_t *ba = A ? A->buf : nullptr, *bb = B ? B->buf : nullptr;
    delete A;
    A = nullptr;
    delete B;
    B = nullptr;
    ctrl_close(ctrl);
    if (dev) {
      if (ba) dev->arena_free(ba);
      if (bb) dev->arena_free(bb);
    }
    delete dev;
    dev = nullptr;
  }
};

static int peer_of(int world, int rank, int link) {
  if (link == 0) return rank ^ 1;
  return world == 4 ? (rank ^ 3) : rank;   /* world=2: linkB 自环 */
}

/* 标志等待: deadline + abort(本端字/门铃 flags/控制面) + dev_err 全面检查 (强化一/二)
 *
 * 匹配语义: 本端旗标 (producer/arm1/done) 严格 v==expect —— 同 rank 单写者无偏斜可言,
 * v>expect 即错账 (engine_wait overshoot → PROTOCOL)。
 * 对端门铃的合法超前容忍只在 kernel wait_two 层 (有界 d≤seq+1, 见 ALGORITHMS §4):
 * 分层严格性是协议不变式, 两层语义不可互换。 */
static int engine_wait(Comm *c, volatile uint64_t *word, uint64_t expect) {
  int64_t deadline = now_ms() + c->cfg.timeout_ms;
  uint64_t spins = 0;
  for (;;) {
    uint64_t v = ld_acquire(word);
    if (v == expect) return AR2_OK;
    if (v > expect) {
      const char *wn = word == &c->ctlA->producer ? "prodA"
                       : word == &c->ctlA->send_done ? "sdA"
                       : word == &c->ctlB->arm1      ? "arm1B"
                       : word == &c->ctlB->send_done ? "sdB"
                       : word == &c->ctlB->done      ? "doneB" : "?";
      fprintf(stderr, "[ar2] rank%d engine_wait overshoot word=%s v=%llu expect=%llu seq=%llu\n",
              c->cfg.rank, wn, (unsigned long long)v,
              (unsigned long long)expect, (unsigned long long)c->seq_);
      return AR2_ERR_PROTOCOL;
    }
    if (ld_acquire(&c->ctlA->abort) || ld_acquire(&c->ctlB->abort))
      return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
    uint64_t eA = ld_acquire(&c->ctlA->dev_err), eB = ld_acquire(&c->ctlB->dev_err);
    if (eA || eB) {
      uint64_t e = eA ? eA : eB;
      /* dev_err 打包 = [code:8][seq:32@bit8] (审计修正: obs 字段已随容忍化移除, 不再打印) */
      fprintf(stderr, "[ar2] rank%d kernel err %s code=%lld want-seq=%llu ctr=%llu engine-seq=%llu\n",
              c->cfg.rank, eA ? "linkA" : "linkB", (unsigned long long)(e & 0xFF),
              (unsigned long long)((e >> 8) & 0xFFFFFFFFULL),
              (unsigned long long)ld_acquire(c->seq_words), (unsigned long long)c->seq_);
      return AR2_ERR_PROTOCOL;
    }
    if ((++spins & 0xFF) == 0) {
      uint64_t dA = ld_acquire(&c->ctlA->dbell), dB = ld_acquire(&c->ctlB->dbell);
      if ((dbell_flags(dA) | dbell_flags(dB)) & 1) return AR2_ERR_ABORTED;
      /* 注意: done(n) 等待期间对端 dbellA 可合法推进到 n+1 (领先一 op),
       * 轮内严格性由 kernel wait_two 在正确链路上保证, 此处不做跨轮超前判定 */
    }
    if ((spins & 0xFFF) == 0) {
      int remote = 0;
      if (ctrl_poll_abort(c->ctrl, &remote)) return remote ? remote : AR2_ERR_REMOTE;
      if (now_ms() > deadline) return AR2_ERR_TIMEOUT;
      std::this_thread::yield();
    }
    spin_pause();
  }
}

/* R3: 每 QP 尾 WR 均签名 (wr_id=seq), 共享 CQ 需收齐 nqp 个成功 CQE 才算 burst 完成;
 * 残留 CQE 会污染下一 op 的 wr_id 校验, 故必须计数收齐。 */
static int reap_bell(Link *L, uint64_t seq) {
  int64_t deadline = now_ms() + AR2_QP_TIMEOUT_S * 1000;
  int got = 0, want = L->nqp;
  for (;;) {
    ibv_wc wc{};
    int n = ibv_poll_cq(L->cq, 1, &wc);
    if (n < 0) return AR2_ERR_VERBS;
    if (n == 0) {
      if (now_ms() > deadline) return AR2_ERR_TIMEOUT;
      spin_pause();
      continue;
    }
    if (wc.status != IBV_WC_SUCCESS) {
      fprintf(stderr, "[ar2] bell CQE fail seq=%llu status=%s\n",
              (unsigned long long)seq, ibv_wc_status_str(wc.status));
      return AR2_ERR_VERBS;
    }
    if (wc.wr_id != seq) {
      fprintf(stderr, "[ar2] unexpected CQE wr_id=%llu want %llu\n",
              (unsigned long long)wc.wr_id, (unsigned long long)seq);
      return AR2_ERR_PROTOCOL;
    }
    if (++got == want) return AR2_OK;   /* nqp 个 QP 的尾 WR CQE 全部收齐 */
  }
}

/* 合批 WR: 每 QP [bulk 分段(不签名) → 8B 旗标(inline+签名)] 一次 post (SparkRing 6/op
 * → 2/op → R3 2×nqp/op)。R3 多 QP 条带: bytes 按连续段摊到 nqp 个 RC QP, 让 NIC 并行
 * 跑多条报文流水突破单 QP 带宽; 各 QP 尾旗标落点 —— q=0 → Ar2Ctl.dbell (原协议不变,
 * 兼作 ABORT 通路), q>0 → 对端 seq 区 word(16+q)。RC 队列内有序放置保证: 后发的 inline
 * 旗标到达 ⇒ 本 QP 前面的数据段已落槽, 消费侧 (kernel wait_flag / CPU 镜像) 收齐
 * dbell+全旗标才动槽数据 —— 与单 QP 门铃语义几何等价。条带切分无对齐要求 (RDMA WRITE
 * 任意长度), 余数摊给前段; nqp=1 精确退化为 V5 单 QP 形态 (不写不校验 word16+)。 */
static int post_burst(Comm *c, Link *L, uint32_t slot, uint32_t bytes, uint64_t seq,
                      bool wait_cqe = true) {
  uint64_t remote_recv = L->peer.addr + (uint64_t)slot * c->cfg.smax_bytes;
  uint64_t remote_ctl = L->peer.addr + arena_ctl_off(c->cfg.smax_bytes, c->cfg.nslots);
  uint64_t remote_flags = remote_ctl + sizeof(Ar2Ctl);   /* 对端 seq 区基址 */
  uint64_t db = dbell_word((uint32_t)seq);
  uint8_t *send_slot = L->buf + (size_t)c->cfg.nslots * c->cfg.smax_bytes + (size_t)slot * c->cfg.smax_bytes;
  int nqp = L->nqp;
  uint32_t chunk = bytes / (uint32_t)nqp, rem = bytes % (uint32_t)nqp;
  uint32_t off = 0;
  for (int q = 0; q < nqp; q++) {
    uint32_t len = chunk + ((uint32_t)q < rem ? 1u : 0u);
    uint64_t flag_addr = (q == 0) ? remote_ctl                          /* dbell 字 (Ar2Ctl 偏移 0) */
                                  : remote_flags + (AR2_SEQ_FLAG_WORD + q) * 8;
    ibv_sge sge[2]{};
    ibv_send_wr wr[2]{};
    sge[0].addr = (uintptr_t)(send_slot + off);
    sge[0].length = len;
    sge[0].lkey = L->mr->lkey;
    wr[0].opcode = IBV_WR_RDMA_WRITE;
    wr[0].wr.rdma.remote_addr = remote_recv + off;
    wr[0].wr.rdma.rkey = L->peer.rkey;
    wr[0].sg_list = &sge[0];
    wr[0].num_sge = 1;
    wr[0].send_flags = (len <= 64) ? IBV_SEND_INLINE : 0;
    sge[1].addr = (uintptr_t)&db;   /* 8B 旗标值 (栈上; IBV_SEND_INLINE 于 post 时即取, 无生命周期问题) */
    sge[1].length = 8;
    sge[1].lkey = L->mr->lkey;
    wr[1].wr_id = seq;
    wr[1].opcode = IBV_WR_RDMA_WRITE;
    wr[1].wr.rdma.remote_addr = flag_addr;
    wr[1].wr.rdma.rkey = L->peer.rkey;
    wr[1].sg_list = &sge[1];
    wr[1].num_sge = 1;
    wr[1].send_flags = IBV_SEND_INLINE | IBV_SEND_SIGNALED;
    wr[0].next = &wr[1];
    ibv_send_wr *bad = nullptr;
    if (ibv_post_send(L->qp[q], &wr[0], &bad)) return AR2_ERR_VERBS;
    off += len;
  }
  L->sent_seq = seq;
  if (!wait_cqe) return AR2_OK;   /* P1 解耦: 只投递不等 ACK —— 门铃 RC 有序, 数据依赖
                                     * 自行排序; CQE 由调用方在 op 尾部收齐 (防污染下 op) */
  return reap_bell(L, seq);
}

/* 强化一: abort 传播 = 本地字 + 双链 ABORT 门铃 + 控制面广播 */
static void abort_path(Comm *c, int reason) {
  /* P1 诊断: 到达计数器/协议字快照 (定位多 block 卡点) */
  if (getenv("AR2_DUMP")) {
    volatile uint64_t *w = c->seq_words;
    fprintf(stderr, "[dump] rank%d reason=%d prod=%llu dbellA=%llu sdA=%llu arm1=%llu dbellB=%llu sdB=%llu done=%llu "
            "arr=%llu,%llu,%llu seqctr=%llu hostseq=%llu\n",
            c->cfg.rank, reason,
            (unsigned long long)ld_acquire(&c->ctlA->producer), (unsigned long long)ld_acquire(&c->ctlA->dbell),
            (unsigned long long)ld_acquire(&c->ctlA->send_done),
            (unsigned long long)ld_acquire(&c->ctlB->arm1), (unsigned long long)ld_acquire(&c->ctlB->dbell),
            (unsigned long long)ld_acquire(&c->ctlB->send_done), (unsigned long long)ld_acquire(&c->ctlB->done),
            (unsigned long long)ld_acquire(w + 4), (unsigned long long)ld_acquire(w + 5),
            (unsigned long long)ld_acquire(w + 6), (unsigned long long)ld_acquire(w), c->seq_);
  }
  /* 审计 F2 修复: 先 reason 后 poisoned (均原子), 消费侧零值兜底 — 跨线程 abort 不再可能
   * 观察到 poisoned=true 而 reason=0 (会被当 AR2_OK 假成功) */
  if (!__atomic_load_n(&c->poisoned, __ATOMIC_RELAXED)) {
    __atomic_store_n(&c->poison_reason, reason, __ATOMIC_RELAXED);
    __atomic_store_n(&c->poisoned, true, __ATOMIC_RELEASE);
  }
  if (__atomic_load_n(&c->abort_sent, __ATOMIC_RELAXED)) return;
  __atomic_store_n(&c->abort_sent, true, __ATOMIC_RELAXED);
  if (c->ctlA) st_release(&c->ctlA->abort, 1);
  if (c->ctlB) st_release(&c->ctlB->abort, 1);
  Link *ls[2] = {c->A, c->B};
  for (Link *L : ls) {
    if (!L || !L->peer.addr) continue;
    uint64_t db = dbell_word(0, 1);
    uint64_t remote_ctl = L->peer.addr + arena_ctl_off(c->cfg.smax_bytes, c->cfg.nslots);
    ibv_sge sge{};
    sge.addr = (uintptr_t)&db;
    sge.length = 8;
    sge.lkey = L->mr->lkey;
    ibv_send_wr wr{};
    wr.opcode = IBV_WR_RDMA_WRITE;
    wr.wr.rdma.remote_addr = remote_ctl;
    wr.wr.rdma.rkey = L->peer.rkey;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.send_flags = IBV_SEND_INLINE;
    ibv_send_wr *bad = nullptr;
    ibv_post_send(L->qp[0], &wr, &bad);   /* 尽力而为, 不签名无 CQE; QP0 = ABORT 门铃通路 */
  }
  ctrl_broadcast_abort(c->ctrl, reason);
  fprintf(stderr, "[ar2] abort rank=%d reason=%d (%s)\n", c->cfg.rank, reason, ar2_strerror(reason));
}

static void build_ptrs(Comm *c, Ar2OpPtrs *p) {
  size_t send_off = (size_t)c->cfg.nslots * c->cfg.smax_bytes;
  p->ctlA = c->ctlA;
  p->ctlB = c->ctlB;
  p->recvA = c->A->buf;
  p->sendA = c->A->buf + send_off;
  p->recvB = c->B->buf;
  p->sendB = c->B->buf + send_off;
  p->seq_ctr = c->seq_words;         /* word0 = device claim 计数器 */
  p->skew_ctr = c->seq_words + 1;    /* word1 = 偏斜命中计数 (诊断) */
  p->arr_ctr = c->seq_words + 4;     /* word4/5/6 = P1 三相到达计数器 */
  /* R3: 各链自己的 arena seq 区 word16 起 = 对端 QPq>0 旗标落点 (对端写, 本端读) */
  p->flagsA = c->seq_words + AR2_SEQ_FLAG_WORD;
  p->flagsB = (volatile uint64_t *)((uint8_t *)c->ctlB + sizeof(Ar2Ctl)) + AR2_SEQ_FLAG_WORD;
  p->smax = c->cfg.smax_bytes;
  p->nslots = c->cfg.nslots;
  p->nqp = c->cfg.nqp;
}

/* 审计A3 修复: done 等待失败的微秒竞态窗口 —— engine_wait(done) 判超时/abort 的瞬间,
 * kernel 可能已通过最后一次 wait_two 并正在 (正确地) 写回用户缓冲 + 发布 done。
 * 此时按失败返回会让 V5 hook 原生重做, 读到已归约输入 → 2Σ 静默错误。处置: 失败后
 * 有界宽限 (≤100ms) 复查 done==seq, 已发布则按成功处理 (数据正确且完整)。 */
static int done_wait(Comm *c, uint64_t seq) {
  int err = engine_wait(c, &c->ctlB->done, seq);
  if (err == AR2_OK) return AR2_OK;
  int64_t dl = now_ms() + 100;
  while (now_ms() < dl) {
    if (ld_acquire(&c->ctlB->done) == seq) {
      fprintf(stderr, "[ar2] rank%d done grace: recovered after rc=%d (kernel was mid-final)\n",
              c->cfg.rank, err);
      return AR2_OK;
    }
    spin_pause();
  }
  return err;
}

/* M1 单 op 五拍序列 (ARCHITECTURE §5): stage+claim(kernel) → 等 producer → postA →
 * 里程碑1(round0 归约+arm1) → 等 arm1 → postB → 里程碑2(round1 归约+终写) → 等 done。
 * engine 逐拍 host 阻塞 —— 这是 V5 语义契约的核心: 返回即数据就绪 (调用方可立即消费),
 * 代价是放弃 NCCL 式异步入队流水; 仅限时延敏感小消息 (NCCL ringonly V5 定位)。 */
static int allreduce_one(Comm *c, uint8_t *x, uint32_t bytes, void *ext_stream = nullptr) {
  if (__atomic_load_n(&c->poisoned, __ATOMIC_ACQUIRE))
    return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
  if (!x || ((uintptr_t)x & 15) || bytes < 16 || (bytes & 15) || bytes > c->cfg.smax_bytes)
    return AR2_ERR_INVALID;   /* 审计修复: 补 buf 指针 16 对齐校验 (kernel __ldcv 硬约束) */
  /* op 入口 abort 预检: 对端已 ABORT 时不再向其 QP post (省 transport retry 秒级等待) */
  if (ld_acquire(&c->ctlA->abort) || ld_acquire(&c->ctlB->abort)) {
    abort_path(c, AR2_ERR_ABORTED);
    return c->poison_reason;
  }
  {
    uint64_t dA = ld_acquire(&c->ctlA->dbell), dB = ld_acquire(&c->ctlB->dbell);
    if ((dA && ((dbell_flags(dA) & 1) || !dbell_magic_ok(dA))) ||
        (dB && ((dbell_flags(dB) & 1) || !dbell_magic_ok(dB)))) {
      abort_path(c, AR2_ERR_ABORTED);
      return c->poison_reason;
    }
  }
  uint64_t seq = ++c->seq_;
  uint32_t slot = (uint32_t)((seq - 1) % (uint64_t)c->cfg.nslots);
  Ar2OpPtrs p;
  build_ptrs(c, &p);
  /* P1 profiling: 六拍分段计时 (submit→producer→postA→arm1→postB→done) */
  static const bool prof = getenv("AR2_PROFILE") != nullptr;
  auto T0 = std::chrono::steady_clock::now();
  auto dus = [](std::chrono::steady_clock::time_point a) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - a).count();
  };
  double t_sub = 0, t_prod = 0, t_pA = 0, t_arm = 0, t_pB = 0, t_done = 0;
  /* V5: ext_stream 非空时 kernel 落在调用方流上 (输入/输出流序自动保证); 引擎仍阻塞至完成 */
  int err = c->dev->op_submit(ext_stream, x, bytes, seq, slot, p);   /* kernel claim seq */
  t_sub = dus(T0);
  if (err) {
    abort_path(c, err);
    return err;
  }
  if ((err = c->dev->prepare_milestone(x, bytes, seq, slot, p, 0))) { abort_path(c, err); return err; }
  if ((err = engine_wait(c, &c->ctlA->producer, seq))) { abort_path(c, err); return err; }
  t_prod = dus(T0);
  /* P1 解耦 (尺寸门控): <256K 时 post 即返 —— send_done 提前释放, kernel 的 rA 消费
   * 仅依赖对端门铃 (RC 有序 ⇒ 门铃到 ⇒ 本端数据段已落槽), 两链 CQE op 尾收齐;
   * ≥256K 保持阻塞 —— 两轮飞行重叠会打满同卡共享 PCIe x4, 尾延迟反噬 (1M p90 实测
   * 379→504), 阻塞形态更稳 */
  bool dec = bytes < 262144;
  if ((err = post_burst(c, c->A, slot, bytes, seq, !dec))) { abort_path(c, err); return err; }
  t_pA = dus(T0);
  st_release(&c->ctlA->send_done, seq);
  if ((err = c->dev->prepare_milestone(x, bytes, seq, slot, p, 1))) { abort_path(c, err); return err; }
  if ((err = engine_wait(c, &c->ctlB->arm1, seq))) { abort_path(c, err); return err; }
  t_arm = dus(T0);
  if ((err = post_burst(c, c->B, slot, bytes, seq, !dec))) { abort_path(c, err); return err; }
  t_pB = dus(T0);
  st_release(&c->ctlB->send_done, seq);
  if ((err = c->dev->prepare_milestone(x, bytes, seq, slot, p, 2))) { abort_path(c, err); return err; }
  if ((err = done_wait(c, seq))) { abort_path(c, err); return err; }
  t_done = dus(T0);
  if (dec && ((err = reap_bell(c->A, seq)) || (err = reap_bell(c->B, seq)))) { abort_path(c, err); return err; }
  c->completed_++;
  if (prof)
    fprintf(stderr, "[prof] rank%d S=%u sub=%.1f prod=%.1f postA=%.1f arm1=%.1f postB=%.1f done=%.1f\n",
            c->cfg.rank, bytes, t_sub, t_prod - t_sub, t_pA - t_prod, t_arm - t_pA, t_pB - t_arm, t_done - t_pB);
  return AR2_OK;
}


/* M2 replay: kernels 已在 graph 内序执行, host 逐 op 驱动 WR。
 * M2GI 重构: 驱动循环抽出为 layer_drive (kernel 启动方式解耦) ——
 *   旧 API ar2_allreduce_layer: 自有 graph (c->graph) launch + drive;
 *   M2GI GI-A: kernel 由调用方 (vLLM) 捕进它自己的 FULL 图, 重放期仅调 drive。 */
static int layer_drive(Comm *c, const GraphState &g) {
  uint64_t base = c->seq_ + 1;
  int nslots = c->cfg.nslots;
  c->seq_ = base + (uint64_t)g.n - 1;   /* claim 由 kernel 执行时原子递增, 引擎按算术对齐;
                                         * M2GI 约束: ar2 承载图须单流程序序重放 (drive 紧随 launch) */
  Ar2OpPtrs p;
  build_ptrs(c, &p);
  int err;
  for (int i = 0; i < g.n; i++) {
    uint64_t seq = base + (uint64_t)i;
    uint32_t slot = (uint32_t)((seq - 1) % (uint64_t)nslots);
    if ((err = engine_wait(c, &c->ctlA->producer, seq))) { abort_path(c, err); return err; }
    c->log_mark(seq, slot, g.bytes[i], 0, ld_acquire(c->seq_words + 2), ld_acquire(c->seq_words + 3));   /* 金丝雀: kernel 读到/写出的首元素 */
    c->log_mark(seq, slot, g.bytes[i], 1, *(const uint64_t *)(c->A->buf + (size_t)c->cfg.nslots * c->cfg.smax_bytes + (size_t)slot * c->cfg.smax_bytes));   /* pre-postA send 槽首 8B */
    if ((err = post_burst(c, c->A, slot, g.bytes[i], seq))) { abort_path(c, err); return err; }
    st_release(&c->ctlA->send_done, seq);
    if ((err = engine_wait(c, &c->ctlB->arm1, seq))) { abort_path(c, err); return err; }
    c->log_mark(seq, slot, g.bytes[i], 2);
    c->log_mark(seq, slot, g.bytes[i], 3, *(const uint64_t *)(c->B->buf + (size_t)c->cfg.nslots * c->cfg.smax_bytes + (size_t)slot * c->cfg.smax_bytes));   /* pre-postB send 槽首 8B */
    if ((err = post_burst(c, c->B, slot, g.bytes[i], seq))) { abort_path(c, err); return err; }
    st_release(&c->ctlB->send_done, seq);
    if ((err = done_wait(c, seq))) { abort_path(c, err); return err; }
    c->log_mark(seq, slot, g.bytes[i], 4);
    c->log_mark(seq, slot, g.bytes[i], 5, *(const uint64_t *)(c->A->buf + (size_t)slot * c->cfg.smax_bytes));   /* post-done recvA 槽首 8B (kernel 所见) */
    c->log_mark(seq, slot, g.bytes[i], 6, *(const uint64_t *)(c->B->buf + (size_t)slot * c->cfg.smax_bytes));   /* post-done recvB 槽首 8B */
    c->completed_++;
  }
  return AR2_OK;
}

static int layer_replay(Comm *c) {
  const GraphState &g = c->graph;
  int err = c->dev->launch_graph(nullptr);
  if (err) {
    abort_path(c, err);
    return err;
  }
  return layer_drive(c, g);
}

static bool graph_matches(const Comm *c, void *const bufs[], const uint32_t bytes[], int n) {
  const GraphState &g = c->graph;
  if (!g.valid || g.n != n) return false;
  for (int i = 0; i < n; i++)
    if (g.bufs[i] != bufs[i] || g.bytes[i] != bytes[i]) return false;
  return true;
}

}  // namespace ar2

/* ---------------- C API ---------------- */
struct ar2_comm {
  ar2::Comm c;
};

using namespace ar2;

void ar2_config_defaults(ar2_config *cfg) {
  if (!cfg) return;
  memset(cfg, 0, sizeof *cfg);
  cfg->world = 4;
  cfg->ctrl_port = 9500;
  cfg->gid_index = 3;
  /* timeout_ms / smax_bytes / nslots / nqp 留 0 = "未设"哨兵, 由 ar2_init 做 env 回退
   * (AR2_TIMEOUT_MS / AR2_SMAX / AR2_NSLOTS / AR2_QPS → 5000 / 65536 / 2 / 1)。
   * R3 审计修正: 原实现预填 5000/65536/2 非零值, 令上述 env 回退全部成死代码 ——
   * AR2_SMAX 从未生效过 (大尺寸微基准被静默钳在 64KB 即此因)。dtype/backend 语义不变。 */
  cfg->dtype = AR2_DT_BF16;
  cfg->backend = -1;   /* auto */
}

static uint32_t env_u32(const char *k, uint32_t dflt) {
  const char *v = getenv(k);
  return (v && *v) ? (uint32_t)strtoul(v, nullptr, 10) : dflt;
}

/* 建连总装 (顺序即依赖, 任一步失败整体回滚):
 *  ① 设备后端 + 双 arena (arena_alloc 内含清零)
 *  ② 双 verbs 链路 setup (PD/CQ/QP/MR 注册 arena)
 *  ③ TCP 星型 ctrl_connect (rank0 聚合; 无效连接丢弃续等)
 *  ④ PeerInfo 全交换 + 几何校验 (magic/version/smax/nslots/dtype/addr)
 *  ⑤ 双 link_connect (RTR/RTS; gid_index 来自配置)
 *  ⑥ ready barrier —— 全员 RTS 后才放行首个 op (未 RTS 的对端会拖 transport retry 秒级)
 * 成功后所有权 steal 给 wrapper; 失败打印 stage 并释放全部资源。 */
int ar2_init(const ar2_config *cfg_in, ar2_comm **out) {
  if (!cfg_in || !out) return AR2_ERR_INVALID;
  *out = nullptr;
  ar2_config cfg = *cfg_in;
  if (cfg.timeout_ms <= 0) cfg.timeout_ms = (int)env_u32("AR2_TIMEOUT_MS", 5000);
  if (cfg.smax_bytes == 0) cfg.smax_bytes = env_u32("AR2_SMAX", 65536);
  if (cfg.nslots == 0) cfg.nslots = (int)env_u32("AR2_NSLOTS", 2);
  if (cfg.nqp == 0) cfg.nqp = (int)env_u32("AR2_QPS", 1);   /* R3: 0/未设 = 单 QP 原形态 */
  if (cfg.ctrl_port == 0) cfg.ctrl_port = 9500;
  if (cfg.gid_index == 0) cfg.gid_index = 3;
  if (cfg.backend == -1) cfg.backend = (make_cuda_device != nullptr) ? AR2_BACKEND_CUDA : AR2_BACKEND_CPU;

  if ((cfg.world != 4 && cfg.world != 2) || cfg.rank < 0 || cfg.rank >= cfg.world)
    return AR2_ERR_INVALID;
  if (!cfg.dev0 || !cfg.dev1 || !strcmp(cfg.dev0, cfg.dev1)) return AR2_ERR_INVALID;
  if (cfg.smax_bytes < 64 || (cfg.smax_bytes & 15) || cfg.smax_bytes > (1u << 20)) return AR2_ERR_INVALID;
  if (cfg.nslots < 1 || cfg.nslots > 8) return AR2_ERR_INVALID;
  if (cfg.nqp < 1 || cfg.nqp > AR2_MAX_QPS) return AR2_ERR_INVALID;   /* R3 几何: 越界即拒 */
  if (cfg.timeout_ms < 100 || cfg.timeout_ms > 3600000) return AR2_ERR_INVALID;
  if (cfg.backend == AR2_BACKEND_CUDA && cfg.dtype != AR2_DT_BF16) return AR2_ERR_UNSUPPORTED;
  if (cfg.backend == AR2_BACKEND_CPU && cfg.dtype != AR2_DT_FP32) return AR2_ERR_UNSUPPORTED;

  Comm *m = new (std::nothrow) Comm();
  if (!m) return AR2_ERR_NOMEM;
  m->cfg = cfg;
  bool trace = getenv("AR2_TRACE") != nullptr;
  int rc = AR2_ERR_FATAL;
  do {
    if (trace) fprintf(stderr, "[trace] rank%d make_device\n", cfg.rank);
    m->dev = (cfg.backend == AR2_BACKEND_CUDA) ? make_cuda_device() : make_cpu_device(cfg.dtype);
    if (!m->dev) { rc = AR2_ERR_NOMEM; break; }
    m->dev->set_timeout(cfg.timeout_ms);
    if (trace) fprintf(stderr, "[trace] rank%d arena\n", cfg.rank);
    size_t ab = arena_bytes(cfg.smax_bytes, cfg.nslots);
    uint8_t *arenaA = m->dev->arena_alloc(ab);
    uint8_t *arenaB = m->dev->arena_alloc(ab);
    if (!arenaA || !arenaB) { rc = AR2_ERR_NOMEM; break; }
    if (trace) fprintf(stderr, "[trace] rank%d links\n", cfg.rank);
    m->A = new (std::nothrow) Link();
    m->B = new (std::nothrow) Link();
    if (!m->A || !m->B) { rc = AR2_ERR_NOMEM; break; }
    if ((rc = link_setup(m->A, cfg.dev0, arenaA, ab, cfg.nqp)) != AR2_OK) break;
    if ((rc = link_setup(m->B, cfg.dev1, arenaB, ab, cfg.nqp)) != AR2_OK) break;
    if (trace) fprintf(stderr, "[trace] rank%d links up\n", cfg.rank);
    m->ctlA = (volatile Ar2Ctl *)(arenaA + arena_ctl_off(cfg.smax_bytes, cfg.nslots));
    m->ctlB = (volatile Ar2Ctl *)(arenaB + arena_ctl_off(cfg.smax_bytes, cfg.nslots));
    m->seq_words = (volatile uint64_t *)((uint8_t *)m->ctlA + sizeof(Ar2Ctl));

    if ((rc = ctrl_connect(m->ctrl, cfg)) != AR2_OK) {
      fprintf(stderr, "[ar2] rank%d ctrl_connect rc=%d\n", cfg.rank, rc);
      break;
    }
    PeerInfo mine[2], all[4][2];
    memset(all, 0, sizeof all);
    fill_peer_info(m->A, &mine[0], cfg.rank, cfg.dtype, cfg.smax_bytes, cfg.nslots, cfg.gid_index);
    fill_peer_info(m->B, &mine[1], cfg.rank, cfg.dtype, cfg.smax_bytes, cfg.nslots, cfg.gid_index);
    {   /* gid 全零 = 查询失败, 提前终止 (审计修复) */
      bool bad_gid = false;
      for (int l = 0; l < 2 && !bad_gid; l++)
        for (int b = 0; b < 16; b++)
          if (mine[l].gid[b]) break;
          else if (b == 15) bad_gid = true;
      if (bad_gid) { rc = AR2_ERR_VERBS; break; }
    }
    size_t pack = sizeof(PeerInfo) * 2;
    if (cfg.rank == 0) {
      memcpy(all[0], mine, pack);
      for (int r = 1; r < cfg.world; r++)
        if (!tcp_recv_all(m->ctrl.fds[r], all[r], pack, 10000)) { rc = AR2_ERR_VERBS; break; }
      if (rc != AR2_OK) break;
      for (int r = 1; r < cfg.world; r++)
        if (!tcp_send_all(m->ctrl.fds[r], all, pack * 4, 10000)) { rc = AR2_ERR_VERBS; break; }
      if (rc != AR2_OK) break;
    } else {
      if (!tcp_send_all(m->ctrl.fds[0], mine, pack, 10000)) { rc = AR2_ERR_VERBS; break; }
      if (!tcp_recv_all(m->ctrl.fds[0], all, pack * 4, 10000)) { rc = AR2_ERR_VERBS; break; }
    }
    /* 几何校验 (SparkRing EndpointInfo 范式; R3: nqp 也入校验 —— 条带协议要求双方 QP 数一致) */
    for (int r = 0; r < cfg.world; r++) {
      for (int l = 0; l < 2; l++) {
        if (all[r][l].magic != 0xA2C0A2C0u || all[r][l].version != AR2_VERSION ||
            all[r][l].smax != cfg.smax_bytes || all[r][l].nslots != (uint32_t)cfg.nslots ||
            all[r][l].dtype != (uint16_t)cfg.dtype || all[r][l].addr == 0 ||
            all[r][l].nqp != (uint8_t)cfg.nqp) {
          fprintf(stderr, "[ar2] geometry mismatch with rank%d link%d\n", r, l);
          rc = AR2_ERR_PROTOCOL;
        }
      }
    }
    if (rc != AR2_OK) break;
    int pA = peer_of(cfg.world, cfg.rank, 0), pB = peer_of(cfg.world, cfg.rank, 1);
    if ((rc = link_connect(m->A, all[pA][0], cfg.gid_index)) != AR2_OK) {
      fprintf(stderr, "[ar2] rank%d linkA connect peer=%d rc=%d\n", cfg.rank, pA, rc);
      break;
    }
    if ((rc = link_connect(m->B, all[pB][1], cfg.gid_index)) != AR2_OK) {
      fprintf(stderr, "[ar2] rank%d linkB connect peer=%d rc=%d\n", cfg.rank, pB, rc);
      break;
    }
    /* ready barrier: 全员 RTS 后放行 (proto v2 教训) */
    uint8_t x = 1;
    if (cfg.rank == 0) {
      for (int r = 1; r < cfg.world; r++)
        if (!tcp_recv_all(m->ctrl.fds[r], &x, 1, 10000)) { rc = AR2_ERR_VERBS; break; }
      for (int r = 1; r < cfg.world; r++)
        if (!tcp_send_all(m->ctrl.fds[r], &x, 1, 10000)) { rc = AR2_ERR_VERBS; break; }
    } else {
      if (!tcp_send_all(m->ctrl.fds[0], &x, 1, 10000) ||
          !tcp_recv_all(m->ctrl.fds[0], &x, 1, 10000))
        rc = AR2_ERR_VERBS;
    }
    if (rc != AR2_OK) break;
    ar2_comm *w = new (std::nothrow) ar2_comm();
    if (!w) { rc = AR2_ERR_NOMEM; break; }
    w->c.steal(m);
    *out = w;
    return AR2_OK;
  } while (0);
  if (rc != AR2_OK) fprintf(stderr, "[ar2] init fail rank=%d stage rc=%d (%s)\n", cfg.rank, rc, ar2_strerror(rc));
  delete m;
  return rc;
}

int ar2_allreduce(ar2_comm *w, void *buf, uint32_t bytes) {
  if (!w) return AR2_ERR_INVALID;
  return allreduce_one(&w->c, (uint8_t *)buf, bytes);
}

int ar2_allreduce_stream(ar2_comm *w, void *buf, uint32_t bytes, void *cuda_stream) {
  if (!w) return AR2_ERR_INVALID;
  return allreduce_one(&w->c, (uint8_t *)buf, bytes, cuda_stream);
}

/* ---------------- M2GI GI-A: vLLM 图内集成 API ----------------
 * 形态: vLLM FULL 图捕获期调 capture_op_stream 把 ar2 fused kernel 录进它的图
 * (捕获流不执行 —— host 协议不跑, 与 m1 的阻塞语义刻意分离); 捕获结束 register
 * 层表; 重放期 launch 它的图后立即 drive (host WR 五拍驱动, kernel 门铃自旋在图内)。
 * 约束: ar2 承载图须单流程序序重放且 drive 紧随 launch (seq claim 算术对齐前提);
 *       与 m1/hook 路径不得混用同一会话 (seq 消费者唯一性)。 */
int ar2_capture_op_stream(ar2_comm *w, void *buf, uint32_t bytes, void *cuda_stream) {
  if (!w || !buf) return AR2_ERR_INVALID;
  Comm *c = &w->c;
  if (__atomic_load_n(&c->poisoned, __ATOMIC_ACQUIRE))
    return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
  uint8_t *x = (uint8_t *)buf;
  if (((uintptr_t)x & 15) || bytes < 16 || (bytes & 15) || bytes > c->cfg.smax_bytes)
    return AR2_ERR_INVALID;   /* 与 allreduce_one 同校验 (kernel __ldcv 硬约束) */
  Ar2OpPtrs p;
  build_ptrs(c, &p);
  return c->dev->op_submit(cuda_stream, x, bytes, 0, 0, p);   /* seq/slot: kernel 执行期自 claim */
}

int ar2_layer_register(ar2_comm *w, uint32_t *gid, void *const bufs[], const uint32_t bytes[], int n) {
  if (!w || !gid || !bufs || !bytes) return AR2_ERR_INVALID;
  Comm *c = &w->c;
  if (__atomic_load_n(&c->poisoned, __ATOMIC_ACQUIRE))
    return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
  if (n < 1 || n > AR2_MAX_LAYER_OPS || c->ngraphs >= AR2_MAX_GRAPHS) return AR2_ERR_INVALID;
  for (int i = 0; i < n; i++) {
    if (!bufs[i] || ((uintptr_t)bufs[i] & 15) || bytes[i] < 16 || (bytes[i] & 15) ||
        bytes[i] > c->cfg.smax_bytes)
      return AR2_ERR_INVALID;   /* 拒绝即整图回原生 (调用方语义: register 失败 → gid 不生效) */
  }
  GraphState &g = c->gtab[c->ngraphs];
  g.valid = true;
  g.n = n;
  for (int i = 0; i < n; i++) {
    g.bufs[i] = bufs[i];
    g.bytes[i] = bytes[i];
  }
  *gid = (uint32_t)c->ngraphs++;
  return AR2_OK;
}

int ar2_layer_drive(ar2_comm *w, uint32_t gid) {
  if (!w) return AR2_ERR_INVALID;
  Comm *c = &w->c;
  if (gid >= (uint32_t)c->ngraphs || !c->gtab[gid].valid) return AR2_ERR_INVALID;
  return layer_drive(c, c->gtab[gid]);
}

int ar2_arm_fence(ar2_comm *w) {
  if (!w) return AR2_ERR_INVALID;
  return ctrl_arm_fence(w->c.ctrl);
}

int ar2_capture_layer(ar2_comm *w, void *const bufs[], const uint32_t bytes[], int n) {
  if (!w || !bufs || !bytes || n < 1 || n > AR2_MAX_LAYER_OPS) return AR2_ERR_INVALID;
  Comm *c = &w->c;
  if (__atomic_load_n(&c->poisoned, __ATOMIC_ACQUIRE))
    return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
  if (c->cfg.backend != AR2_BACKEND_CUDA) return AR2_ERR_UNSUPPORTED;
  if (getenv("AR2_NO_GRAPH")) return AR2_ERR_UNSUPPORTED;   /* 判别器: layer 走 M1 串行回退 */
  for (int i = 0; i < n; i++)
    if (!bufs[i] || ((uintptr_t)bufs[i] & 15) || bytes[i] < 16 || (bytes[i] & 15) ||
        bytes[i] > c->cfg.smax_bytes)
      return AR2_ERR_INVALID;
  Ar2OpPtrs p;
  build_ptrs(c, &p);
  int rc = c->dev->capture_layer(nullptr, (uint8_t *const *)bufs, bytes, c->seq_ + 1, c->seq_words, &p, n);
  if (rc != AR2_OK) {
    c->graph.valid = false;   /* 审计修复: dev 层已销毁旧 gexec, 失配态须失效, 否则下次 replay 毒化健康会话 */
    return rc;
  }
  c->graph.valid = true;
  c->graph.n = n;
  for (int i = 0; i < n; i++) {
    c->graph.bufs[i] = bufs[i];
    c->graph.bytes[i] = bytes[i];
  }
  return AR2_OK;
}

int ar2_allreduce_layer(ar2_comm *w, void *const bufs[], const uint32_t bytes[], int n) {
  if (!w || !bufs || !bytes || n < 1 || n > AR2_MAX_LAYER_OPS) return AR2_ERR_INVALID;
  Comm *c = &w->c;
  if (__atomic_load_n(&c->poisoned, __ATOMIC_ACQUIRE))
    return c->poison_reason ? c->poison_reason : AR2_ERR_ABORTED;
  if (graph_matches(c, bufs, bytes, n)) return layer_replay(c);
  int rc = AR2_OK;
  for (int i = 0; i < n; i++)
    if ((rc = allreduce_one(c, (uint8_t *)bufs[i], bytes[i])) != AR2_OK) break;
  return rc;
}

int ar2_abort(ar2_comm *w, int reason) {
  if (!w) return AR2_ERR_INVALID;
  abort_path(&w->c, reason ? reason : AR2_ERR_ABORTED);
  int r = w->c.poison_reason;
  return r ? r : AR2_ERR_ABORTED;   /* 审计 F2: 竞态窗口零值兜底 */
}

int ar2_finalize(ar2_comm **wp) {
  if (!wp || !*wp) return AR2_OK;
  Comm *c = &(*wp)->c;
  c->dev->sync_stream(nullptr);          /* kernel abort 感知 → 正常退出; 5s 上限在 dev 内 */
  uint64_t skew = ld_acquire(c->seq_words + 1);   /* word1 = 偏斜命中计数 */
  if (skew) fprintf(stderr, "[ar2] rank=%d skew_tolerated=%llu (d==seq+1 早到命中)\n",
                    c->cfg.rank, (unsigned long long)skew);
  if (getenv("AR2_DUMP")) {              /* M2 取证: counter/engine-seq/双 ctl/最近 op 时间线 */
    fprintf(stderr, "[dump] rank=%d engine_seq=%llu claim_ctr=%llu completed=%llu\n",
            c->cfg.rank, (unsigned long long)c->seq_,
            (unsigned long long)ld_acquire(c->seq_words), (unsigned long long)c->completed_);
    for (int L = 0; L < 2; L++) {
      volatile Ar2Ctl *t = L ? c->ctlB : c->ctlA;
      fprintf(stderr, "[dump] rank=%d ctl%s dbell=%llx prod=%llu sd=%llu arm1=%llu done=%llu abort=%llu derr=%llx\n",
              c->cfg.rank, L ? "B" : "A",
              (unsigned long long)t->dbell, (unsigned long long)t->producer,
              (unsigned long long)t->send_done, (unsigned long long)t->arm1,
              (unsigned long long)t->done, (unsigned long long)t->abort,
              (unsigned long long)t->dev_err);
    }
    for (int k = 0; k < 32; k++) {
      const OpLogE &e = c->oplog[(c->oplog_i - k + 32) % 32];
      if (!e.seq) continue;
      fprintf(stderr, "[dump] rank=%d op seq=%llu slot=%u B=%u pa+%lld arm+%lld pb+%lld done+%lld sA=%016llx sB=%016llx rA=%016llx rB=%016llx cx=%016llx cs=%016llx\n",
              c->cfg.rank, (unsigned long long)e.seq, e.slot, e.bytes,
              (long long)(e.t_pa - e.t_prod), (long long)(e.t_arm - e.t_prod),
              (long long)(e.t_pb - e.t_prod), (long long)(e.t_done - e.t_prod),
              (unsigned long long)e.senda_first, (unsigned long long)e.sendb_first,
              (unsigned long long)e.recva_first, (unsigned long long)e.recvb_first,
              (unsigned long long)e.canary_x, (unsigned long long)e.canary_sA);
    }
  }
  uint8_t x = 2;                          /* 尽力而为拆除 barrier */
  if (c->ctrl.rank == 0) {
    for (int r = 1; r < c->ctrl.world; r++)
      if (c->ctrl.fds[r] >= 0) {
        tcp_send_all(c->ctrl.fds[r], &x, 1, 500);
        tcp_recv_all(c->ctrl.fds[r], &x, 1, 500);
      }
  } else if (c->ctrl.fds[0] >= 0) {
    tcp_send_all(c->ctrl.fds[0], &x, 1, 500);
    tcp_recv_all(c->ctrl.fds[0], &x, 1, 500);
  }
  delete *wp;
  *wp = nullptr;
  return AR2_OK;
}

/* ---------------- V5 集成件: env 驱动构造 (NCCL dlopen 消费) ---------------- */
int ar2_init_env(int rank, int world, ar2_comm **out) {
  if (!out) return AR2_ERR_INVALID;
  *out = nullptr;
  const char *peers = getenv("AR2_PEERS");          /* ip0,ip1,ip2,ip3 */
  const char *dev0 = getenv("AR2_DEV0");
  const char *dev1 = getenv("AR2_DEV1");
  if (!peers || !dev0 || !dev1) return AR2_ERR_INVALID;
  /* peer 串拷入进程生命周期静态存储 (API.md 生命周期契约的豁免实现) */
  static char ipbuf[4][64];
  static const char *ips[4];
  int filled = 0;
  const char *p = peers;
  for (int i = 0; i < 4 && filled < 4; i++) {
    size_t n = 0;
    while (*p && *p != ',' && n < sizeof ipbuf[0] - 1) ipbuf[i][n++] = *p++;
    ipbuf[i][n] = 0;
    if (n) { ips[i] = ipbuf[i]; filled++; }
    if (*p == ',') p++;
    if (!*p) break;
  }
  if (filled < 1 || !ips[0]) return AR2_ERR_INVALID;
  ar2_config cfg;
  ar2_config_defaults(&cfg);
  cfg.rank = rank;
  cfg.world = world;
  for (int i = 0; i < 4; i++) cfg.peer_ips[i] = ips[i];   /* 数组成员不能整体赋值; [0] 必填即控制面可达 */
  cfg.dev0 = dev0;
  cfg.dev1 = dev1;
  cfg.ctrl_port = (int)env_u32("AR2_CTRL_PORT", 9520);   /* 默认避开探针 9500 */
  return ar2_init(&cfg, out);
}

int ar2_available(void) { return make_cuda_device != nullptr ? AR2_BACKEND_CUDA : AR2_BACKEND_CPU; }

int ar2_recommended(uint32_t bytes) {
  static uint32_t crossover = 0;
  if (!crossover) crossover = env_u32("AR2_CROSSOVER_B", AR2_CROSSOVER_DEFAULT);
  return bytes <= crossover ? 1 : 0;
}

uint64_t ar2_ops_completed(const ar2_comm *w) { return w ? w->c.completed_ : 0; }

const char *ar2_strerror(int err) {
  switch (err) {
    case AR2_OK: return "ok";
    case AR2_ERR_INVALID: return "invalid argument";
    case AR2_ERR_NOMEM: return "out of memory";
    case AR2_ERR_TIMEOUT: return "timeout";
    case AR2_ERR_ABORTED: return "aborted";
    case AR2_ERR_PROTOCOL: return "protocol error";
    case AR2_ERR_VERBS: return "rdma verbs error";
    case AR2_ERR_POISONED: return "session poisoned";
    case AR2_ERR_UNSUPPORTED: return "unsupported";
    case AR2_ERR_FATAL: return "fatal (process must terminate)";
    case AR2_ERR_REMOTE: return "remote peer error";
    case AR2_ERR_CUDA: return "cuda error";
    default: return "unknown";
  }
}
