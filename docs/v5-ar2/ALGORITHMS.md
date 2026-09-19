# 算法说明 — ar2 核心算法与数学

---

## 1. 两轮全交换 Allreduce（2HOP）数学

**目标**：4 rank 各持向量 x_r，求 `y = Σ_r x_r`，每个 rank 就地得到 y。

**round0（伙伴 rank^1）**：rank r 把 x_r 发给 r^1，收到 x_{r^1}：
```
sB_r = x_r + x_{r^1}          (中间和)
```
**round1（伙伴 rank^3）**：rank r 把 sB_r 发给 r^3，收到 sB_{r^3}：
```
y_r = sB_r + sB_{r^3}
    = (x_r + x_{r^1}) + (x_{r^3} + x_{r^3^1})
    = x_0 + x_1 + x_2 + x_3   ✓ 全和
```
性质：
- 每 rank 总流量 = 2S（两轮各 S）= 理想全互联 3S/4 的 8/3 倍，但**两轮都用单边 WRITE、各走不同网卡**
  → 环内 2 hop 可达任何伙伴（rank^3 经 0-1-2 或 0-3-2），避开交换机
- bf16 就地归约（x 即输出缓冲）——数值语义 = 两次 pairwise 求和（非重排树），bf16 下每步精确舍入

**为什么两轮而不是树/蝶形**：4 rank 蝶形需 log2(4)=2 轮（同深度）但 round1 伙伴随机；本集群
switchless 环只有相邻直连 + 跨环对偶，rank^3 恰好走第二张网卡直连——**拓扑免费**。

## 2. fused kernel 流水（ar2_dev_cuda.cu）

单 block 256 线程，每 op 一个 kernel；关键点 = claim 与等待的线程分工：

```
tid0:  seq = atomicAdd_system(claim_ctr) + 1     ← device 端序号分配
       (broadcast via shared + __syncthreads)
all:   slot = (seq-1) % nslots
       sA = sendA + slot·stride;  rA = recvA + slot·stride; ...
all:   bf16_copy(sA, x, elems)          __stwt   写透
tid0:  fence → canary(取证) → producer=seq
tid0:  err = wait_two(A, seq, skew)     自旋门铃+send_done (其余线程 syncthreads 等待)
all:   bf16_add_wt(sB, sA, rA)          sB = sA+rA   (__ldcv 读对端槽)
tid0:  fence → arm1=seq → wait_two(B, seq, skew)
all:   bf16_add_final(x, sB, rB)        x = sB+rB   (x 为设备内存, 普通写)
tid0:  fence → done=seq
```

- 等待只由 tid0 自旋（`__nanosleep(64)` 退避），其余线程在 `__syncthreads` 处休眠级等待——避免 256 线程同时轰击映射内存
- `err` 经 shared 广播后**全 block 干净退出**（写 dev_err 后 return，无死循环——对比 SparkRing 的无限 nanosleep）
- bf16 向量化：`__nv_bfloat162` + `__hadd2`（4B/迭代），尾部奇数元素 tid0 兜底

## 3. device 端 seq claim（M2 graph replay 安全性）

问题史：早期版本 seq 由 host 写映射字 → graph replay 期间 kernel 读到**上一次的旧值**（host 跨 replay
重写映射字存在旧值执行窗口）→ "kernel 带旧 seq 执行" 实锤（W1 报告）。

方案（SparkRing graph_publish_command 同型）：claim 计数器放 arena（三方可见），
kernel **执行时**原子 +1。graph 每次重放都会重新执行 claim ⇒ seq 天然单调且与执行次数一致。
engine 侧用算术镜像（M1: ++seq_；M2 replay: base=seq_+1, seq_=base+n-1）对齐，正常态两值恒等。

## 4. 有界偏斜容忍（bounded skew tolerance）

**观察**：done(m) 等待期间对端 dbellA 可合法推进到 m+1（对端 op m+1 的 stage 不依赖本端 m 完成——
它只卡在对端自己的 A-wait）。严格 `d==seq` 会把合法状态误判为协议错误。

**容忍界证明**：对端 dbell 到达 m+2 需要什么？
```
对端 bellA(m+2) ← 对端 producer(m+2) ← 对端 kernel(m+2) ← 对端 kernel(m+1) 退役
              ← 对端 B-wait(m+1) 通过 ← 本端 bellB(m+1) ← 本端 arm1(m+1)
              ← 本端 kernel(m+1) 的 A-wait(m+1) ← 本端正在 m 或更早 ⇒ 矛盾
```
⇒ 对端至多领先 1 op。又因槽以 2 为模复用（nslots=2），领先 1 op 时对端 bulk(m+1) 落在**另一槽**，
本端 recv[slot(m)] 内 seq=m 的数据必然完好 ⇒ 接受 `d==seq+1` 是安全的（数据仍正确）。

**实现**：`wait_two`/`wait_dbell` 接受 `ds==seq || ds==seq+1`（后者递增 skew 计数 word1，finalize 打印）；
`ds>seq+1` = 真错账 → PROTOCOL。W3 全部回归 skew=0（容忍未触发，属理论窗口加固）。

**参照**：SparkRing eager kernel 对早到同样容忍；本实现的贡献是把容忍**界**证明并收紧到 +1。

**审计补注**：由于同流 kernel 严格串行（kernel m+1 需 kernel m 退役才启动），对端 stage(m+1)
进一步被本端 bellB(m) 链住——实际运行中 A-wait 处 d==seq+1 分支**不可达**（W3 全程 skew=0 印证）。
容忍保留为防御深度：当且仅当未来改动放松单流串行（engine 异步化/多流）时它才成为活路径；
届时需按本节重新论证界。

## 5. 槽轮转与复用安全

`slot(m)=(m-1)%nslots`。nslots=2 时 op m 与 m+2 同槽，安全性由门铃/CQE 因果链闭合（完整论证见
ARCHITECTURE §7）。要点：**send 槽复用**由 `send_done` + CQE 收割门控；**recv 槽复用**由对端
producer 依赖链（穿过本端 bellB）门控。

## 6. M2 整层固化（CUDA graph）

capture：ThreadLocal 模式捕获 n 个 launch（线性链，保序）→ Instantiate → 固定缓冲指针/字节数。
replay：单次 `cudaGraphLaunch`（enqueue 摊销为 O(1)）+ engine 逐 op 驱动 WR（producer→postA→arm1→postB→done）。
缓冲不匹配（`graph_matches`）自动回退 M1 —— API 面向调用方永远成立。

**实测注记**：12KB×8 op 场景 graph≈串行（38.7 vs 36.1µs/op）——该尺寸 kernel 占主导；
enqueue 摊销收益预期在 ≤4KB/host-bound 段（W2 SIRCL graph submit 实测 3.6µs），
V5 前需按生产几何复测（OPEN-ISSUES #3）。

## 7. abort 级联算法

```
本端发现错误(任一来源) → poison 化 (后续 API 立即返回错误)
                      → 双 ctl.abort=1 (本地 kernel/engine 立即可见)
                      → 双链 ABORT 门铃 (inline 无 CQE, ~µs 级到对端)
                      → TCP 广播 reason (慢路径保底, engine_wait 每 4096 自旋 poll)
对端: kernel 自旋环 / engine 自旋环 / op 入口预检 三处检查点 → 干净退出
```
实测：门铃传播 33µs；kill 测试（rank1 _exit）存活 3 rank ≤6s 干净返回错误码，无挂死。

## 8. 取证算法（AR2_DUMP=1）

- engine 32-op 环形日志：每 op 5 个时间戳（producer/postA/arm1/postB/done, ns）+
  4 个槽首 8B 快照（pre-postA send / pre-postB send / post-done recvA/recvB）+ kernel 金丝雀
  （kernel 实际读到的 x 首元素与写出的 sA 首元素, seq 打包）
- finalize 输出：engine_seq / claim_ctr / completed / 双 ctl 七字 / 环内容
- 金丝雀用途实录：W3 用它定谳"kernel 读到的 x 是旧值"→ 揪出 probe refill 竞态伪影（PITFALLS #13）
