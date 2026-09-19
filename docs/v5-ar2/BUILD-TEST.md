# 构建与测试 — 构建/自测/四机回归/基准

---

## 1. 构建

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8          # 产物: build/ar2_selftest (CPU) + build/ar2_probe (GPU)
```
依赖：CUDA Toolkit（arch 120）、libibverbs-dev、cmake ≥3.24（CMakeLists 声明值）。
CMake 自动探测 CUDA（`check_language`），无 CUDA 时只产 CPU 目标。

### ⚠ 容器内构建纪律（W3 实锤，PITFALLS #14）
宿主机 glibc（2.38）> baked 镜像容器（2.35）时，**宿主机构建的 GPU 二进制在容器内直接
`GLIBC_2.38 not found`**。四机真跑必须在 baked 镜像容器内构建：
```bash
docker run -d --name s2-builder --network host --gpus all -v <本目录>:/src -w /src \
  --entrypoint /bin/bash <baked镜像> -c 'sleep 7200'
docker exec s2-builder bash -c "pip install -q cmake && cd /src && \
  rm -rf build-local && cmake -S . -B build-local -DCMAKE_BUILD_TYPE=Release && \
  cmake --build build-local -j8"
```
（镜像自带 nvcc/CUDA 13.0，cmake 需 pip 装——容器重建后会丢，重装即可。）

### ⚠ 分发纪律（W3 实锤，PITFALLS #12）
远端容器挂载的是**各自宿主机**的本目录副本——改动后必须 rsync 到三台 worker 并 **md5 四机核对**：
```bash
for h in dgxspark02 dgxspark03 dgxspark04; do rsync -a build-local/ar2_probe "$h:<本目录>/build-local/"; done
md5sum build-local/ar2_probe   # ×4 机一致才可开跑
```

## 2. 本机自测（无需 GPU/网络）

```bash
./build/ar2_selftest     # 期望最后一行: === SELFTEST PASSED ===
```
四组用例（tools/ar2_selftest.cpp，world=2 双线程 + CPU 后端）：
- **A 正确性**：fp32 固定 4096/65536 两尺寸 ×100 次，前 10 次比对期望 6.0（审计核对后的实际口径）
- **B 超时+abort**：rank0 300ms deadline + rank1 晚 800ms → rank0 TIMEOUT、rank1 19µs 级 ABORT（门铃级联）
- **C RSS**：10k op 内存增量 <8MB（实测 12KB）
- **D API 契约**：路由交叉点、后端 dtype 拒绝、finalize(nullptr) 安全

注意：在**无 RDMA 权限的容器**（如未 --privileged 的构建容器）里 A/B 会 verbs error、C 的 RSS 读数
失真（cgroup 计数 1TiB）——这是环境限制不是回归，权威判定以宿主机 selftest + 四机真跑为准。

## 3. 四机窗口 runbook

统一纪律（W1-W3 固化）：
1. 停机窗口内（生产服务已按交接单停）；起测试容器 `--privileged --network host --gpus all`
2. **跑前/跑后容器内 `pkill -9 ar2_probe`**——docker exec 不传播 timeout 信号，僵尸会占住 9500 端口
3. 所有远端命令 timeout 包裹；并行跑 4 rank；日志落 `results/`
4. `run_reg.sh` 为参数化单轮执行器（AR2_ENV 透传容器 env），`run_s2.sh` 为固定三模式（m1/layer/kill）

```bash
./run_s2.sh m1          # M1: 5 尺寸 × 220 op
AR2_ENV="AR2_LAYER_NOPS=8 AR2_DUMP=1" ./run_reg.sh <名> --mode layer --iters 400 --warmup 20 --sizes 12288
./run_s2.sh kill        # rank1 定点 _exit → 期望 r0 6s TIMEOUT / r2 r3 秒级 ABORT
```

## 4. 回归矩阵（W3 全绿基线, 2026-09-03）

| 场景 | 规模 | 判据 | 结果 |
|---|---|---|---|
| m1 全尺寸 | 1K/4K/16K/32K/64K × 220 op | 全 rank failures=0 + 首op校验 | ✅ |
| layer NOPS=8 graph | 3280 op（历史失败上限×3.6） | 周期指纹校验 (每50) | ✅ skew=0 |
| layer NOPS=2 | 640 op | 同上 | ✅ |
| layer NO_GRAPH | 2560 op | 同上 | ✅ |
| 逐 op 校验 | 840 op (CHECK_EVERY=1) | 每 op 8 buf 指纹 | ✅ |
| kill 级联 | rank1 _exit@op30 | 存活 3 rank 干净返回 ≤6s | ✅ |
| 本机 selftest | A/B/C/D | 全 PASS | ✅ |

**指纹校验设计**（probe）：buf i 初值 = (rank+1)+2^(i-2) → 一次归约后 = 10+2^i ∈ {11..138}（全部
bf16 精确可表示）；此后每调用 ×4（同值加法精确）。校验公式 `expect(i,t)=ldexpf(10+2^i, 2(t-1))`。
**时序循环中不做 H2D refill**（与 ar2 流竞态，W3 伪影案源，PITFALLS #13）。

## 5. 性能基线（四机实测）

### ar2 M1（NCCL ring 对照 = LuZ 0.4.5 生产库实测）
| S | ar2 avg (µs) | NCCL (µs) | 差 |
|---:|---:|---:|---|
| 1KB | **21.1** | 28.3 | -25% |
| 4KB | **26.0** | 31.4 | -17% |
| 16KB | 45.5 | 38.8 | 落后 ~17%（价值区边界，交还 ring） |
| 32KB | 68.6 | — | — |
| 64KB | 118.6 | 70 | 交还 ring |

### ar2 layer（12288B = DSV4 hidden 生产几何, per-op µs）
| 模式 | avg | p50 | p99 |
|---|---:|---:|---:|
| NOPS=8 graph | 38.7 | 38.2 | 50.9 |
| NOPS=8 NO_GRAPH | 36.1 | 35.9 | 40.0 |
| NOPS=2 | 34.7 | 34.3 | 46.1 |

### 错误模型实测
ABORT 门铃传播 33µs；kill 测试 6s 干净回收；10k op RSS Δ=12KB。

## 6. vLLM 端到端基准（baked-v6 测试镜像, bench_v2.py = LuZ0.4.5 工具链）

前置：baked-v6 测试镜像 = 原 baked + st 库 8d6d2de8 默认化 + ENV NCCL_SKIP_TREE_CONNECT=1（S0 晋升候选）。
W3 复跑全绿：**PR 20/20**（accept=1.0/ok 满额/ct=1.0）、**DE 12/12**（decode_p50 22-100ms, ttft≤1.35s@C6）。
原始日志：`~/sparkring-kit/window-20260903/results/bench-{pr,de}-v6-*.log` 与
`verification-logs/BENCHV2_20260903T{2015,2052}Z/`。
注意：**baked-v6 测试镜像不包含 ar2**（NCCL ringonly V5 模块另集成，见 OPEN-ISSUES #1 结案）；其基准验证的是
skip-tree + st 库栈；ar2 的 E2E 收益验证是 NCCL ringonly V5 模块的验收项。

## 7. 生产窗口纪律（每次开窗必读）

- 起容器前服务必须已 stop；残留 rank 容器先 `docker rm -f`
- bench 长 run（PR ~45min / DE ~50min）不要用 `| tail` 管道（吞输出）；unbuffered 直写日志 + 后台
- 结束按交接单逆序恢复：retag 原镜像（内容级 md5 8c7a5df9 核对）→ head → workers → health=200
  → healthcheck.timer → concurrency-proxy（8001→8002）→ 四机容器/内存核对零残留

---

## 2026-09-04 NCCL ringonly V5 模块正式版构建与验收（E2E 窗口）

**最终交付 md5（2026-09-04 定版审计轮后）**：libnccl.so.2 = `36c26ab6`（NCCL ringonly V5 hook：条件①~⑧ + fence-arm 锁存 + 优雅降级 + V5-HISTO 普查 + A1/A3/A5/B6 审计修复）、
libar2.so.1 = `343bea89`（+`ar2_arm_fence` 共享 deadline/NACK 版 + abort 帧分级缓冲 + done 宽限 + CPU arena 登记 + nothrow）。四机 `~/v5libs/` 一致。
（E2E 窗口验证时的中间版：libnccl `ac2525a0` / libar2 `7c59b387`，血统见 E2E-REPORT §1）

**构建**（baked 镜像容器，无 cmake）：
```bash
# libar2: nvcc 直驱 (CMakeLists 为规范参考)
nvcc -O3 -std=c++17 -arch=sm_120 -Xcompiler -fPIC,-O3 -shared \
  src/ar2_core.cpp src/ar2_dev_cpu.cpp src/ar2_dev_cuda.cu \
  -Iinclude -Isrc -l:libibverbs.so.1 -lcudart -lpthread -o libar2.so.1.0.0
# libnccl: 树必须挂在 /nccl-src 原路径
make -j8 src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODES='-gencode=arch=compute_120,code=sm_120'
```

**验收矩阵**（全部通过）：
- wtest 微基准：dispatched=1105（v3 组规则修复后全量分发）、ok=1、≤8KB 领先 9~43%（需 `AR2_V5_EAGER=1`）
- E2E：四端 `armed via fence`、dspark 捕获 11/11、health=200、冒烟正确
- 双臂 A/B：PR 20/20 + DE 12/12 全绿，中位持平（-0.11% / +0.78%）——持平机理与后续路线见 E2E-REPORT-20260904.md §6 与 OPEN-ISSUES #10
- 生产回退：R5 tag 未动、四机接线回退、health=200、timer+proxy 恢复、8001 冒烟正确


## 2026-09-04 生产镜像轮定版（容器内集成 + 静默窗）

- **libnccl 定版 = `4d8ebaaf`**（在 `36c26ab6` 基础上 + 捕获静默窗(实测#6) + pre-arm 诊断(实测#7)）；
  libar2 = `343bea89`（不变）。
- 生产镜像 `LuZ0.4.5-DeepSeek-v4-Flash-DGXspark-TP4-Ring-V5` digest **81a0c910**（v4）；
  血统：92d3c9f7(v1, 缺静默窗) → 8713a8d9(v2, 漏 libar2 教训) → 1f7c83d2(v3) → **81a0c910(v4 定版)**。
- 验收：四端 armed via fence（静默窗后首个大 AR 触发）、捕获期直方图定格
  （≤8KB 164 op 在图内）、冒烟/并发请求/PR 采样 4 档全绿（2697/2611/916/1017 vs 双臂基线带内）。

---

## 2026-09-04 R3 多 QP 带宽工程构建与验收（负结果定谳, 未晋升生产）

**产物 md5**：libar2.so.1.0.0 = `f47b21fa`（R3 定版：Link 多 QP + post_burst 条带 + 旗标字 +
kernel/CPU wait_flag + AR2_QPS env + defaults env 死代码修复 + launch 错误留痕）；ar2_probe = `34fbf797`
（本地 smax 与库同源读 AR2_SMAX）。**生产不动**：libnccl `51e36db5` + libar2 `343bea89`（四机 ~/v5libs 已同步一致）。
AR2_VERSION 1→2（PeerInfo 布局 qpn[4]+nqp, v1/v2 混布被几何校验拒绝）。

**构建**（v5-builder8 容器, nvcc 直驱, 源经 docker cp 入 /r3src）：
```bash
nvcc -O3 -std=c++17 -arch=sm_120 -Xcompiler -fPIC,-O3 -shared src/ar2_core.cpp src/ar2_dev_cpu.cpp \
  src/ar2_dev_cuda.cu -Iinclude -Isrc -l:libibverbs.so.1 -lcudart -lpthread -o libar2.so.1.0.0
g++ -O2 -std=c++17 tools/ar2_selftest.cpp src/ar2_core.cpp src/ar2_dev_cpu.cpp -Iinclude -Isrc \
  -libverbs -lpthread -o ar2_selftest
nvcc -O3 -std=c++17 -arch=sm_120 -Xcompiler -O3 tools/ar2_probe.cu -Iinclude -L<r3src> -l:libar2.so.1 \
  -lcudart -o ar2_probe
```

**验收矩阵**：selftest nqp=1/2/4 PASSED（nqp=5 拒）; 四机 ar2_probe（wtest 旁路容器, AR2_SMAX=524288,
ctrl 9530）q1f/q2f/q4f 全 rank 零错数据; 微基准结论 = 多 QP 无带宽收益（详见 R3-REPORT-20260904.md）。

**新坑（PITFALLs 同步收录）**：GB10 统一内存下生产 vllm 常驻即占满 → 旁路 CUDA 上下文建立偶发
NOMEM/VERBS/CUDA 混合失败（重试即过; torch set_device 直接 OOM, NCCL 旁路基准与常驻生产不共容,
NCCL 参考取档期窗口数据）。
