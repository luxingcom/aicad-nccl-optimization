# 代码审计报告 — 三子代理交叉验证 + 修复记录

日期：2026-09-03（W3 交付日）
对象：ringonlyV5 交付版（src 4 文件 + tools 2 文件 + include 1 + CMake + docs 10）
方式：三个独立 general-purpose 子代理并行审计（A=协议/并发不变式、B=资源/错误处理/API 契约、
C=文档-代码一致性），互不通信；主会话汇总、修复、复验。
复验：修复后 clean rebuild **0 error 0 warning**，本机 selftest **10/10 PASS**。

---

## 一、审计发现总览

| 来源 | 级别 | 数量 | 判定 |
|---|---|---|---|
| A | P0 | 1（F1 定序缺陷，B 独立复核确认） | 真实缺陷，已修 |
| A+B | P1 | 4（CPU arena 泄漏 / 门铃 u32 回绕 / gid 硬编码 / capture 失败态残留） | 已修 |
| A+B | P2 | ~16 | 已修或已注明 |
| C | 文档 P1 | 1（Ar2Ctl 56B 布局口径） | 已修（含代码注释同步） |
| C | 文档 P2 | 19 | 已修 |
| C | 另自查 | 1（ERROR-MODEL 错误码映射笔误，先于审计发现） | 已修 |

## 二、P0：kernel 里程碑发布缺跨线程屏障（F1）★

- **发现**：A/B 两代理独立指出。`producer/arm1/done` 三处由 tid0 在 `__threadfence_system()`
  后发布，但该 fence **只序 tid0 自身写**；`__syncthreads()` 均在发布**之后**，其余 7 个 warp
  可能仍在写槽/x。后果链：engine 见 producer 即 post → NIC DMA 读到旧槽数据；见 done 即返回 →
  调用方读到部分写完的 x。此前所有测试通过纯属时延掩盖（warp 间偏斜亚微秒级）。
- **修复**：三处改为「数据写 → `__syncthreads()` → tid0 `dev_pub`（fence 在内）」；
  done 同样补屏障（"done ⇒ x 全量写完" 是 API 同步契约）。
- **审计 A 判定原文**：修复后槽复用四方向因果链闭合（其 §1 判定由"不成立（因 F1）"恢复成立）。

## 三、P1 修复明细

1. **CPU 后端 arena 泄漏**（B）：~Comm 从不调 `arena_free`（CUDA 后端靠自身 vector 释放，
   CPU 后端每次会话泄漏 ~513KB）。修复：析构序 = 先拆 Link（dereg MR）→ arena 还后端 → 删后端。
2. **门铃 seq u32 回绕误判**（B，A 降 P3 同源）：`ds > (uint32_t)seq + 1` 在 seq=0xFFFFFFFF
   附近把"对端正常落后 1"误判 PROTOCOL。修复：模 2^32 差 `diff = ds - seq`；
   diff∈{0,1} 通过、0xFFFFFFFF=未到达继续等、其余错账（kernel wait_two 与 CPU wait_dbell 同步修）。
3. **fill_peer_info gid 硬编码 3**（A F4/B）：与 `cfg.gid_index`（建连用）失配，配置非 3 时对端
   拿错 dgid。修复：参数化 + 查询失败（全零 gid）提前 VERBS 终止。
4. **capture 失败后 graph.valid 残留**（B）：dev 层已销毁旧 gexec，core 层不清 valid → 下次同参
   replay 走 launch(INVALID) → 毒化健康会话。修复：失败即 `graph.valid=false`（自动回退 M1）。

## 四、P2 修复清单

| 项 | 修复 |
|---|---|
| poisoned 先于 reason 置位（跨线程 ar2_abort 竞态窗口可读 0=AR2_OK 假成功）| 先 reason 后 poisoned（原子写）；全部消费点 acquire 读 + 零值兜底 ABORTED |
| `ibv_get_device_list` 不释放 | open_dev 内配对 `ibv_free_device_list` |
| tcp send/recv 不处理 EINTR | 显式 continue |
| rank0 accept 无 deadline（缺员永久挂死）| lfd O_NONBLOCK + poll（timeout_ms×24，对齐 worker 240×0.5s）|
| buf 指针 16 对齐契约未校验 | allreduce_one / capture_layer 增 `(uintptr_t)&15` 检查 |
| sync_stream 静默吞 CUDA 粘性错误 | 清理前打印 err+描述 |
| engine_wait 跨对象指针相减 UB + 过期 obs-db 打印 | 改按旗标名打印；obs 字段随容忍化已不存在，打印清理；dev_err 打包口径统一 [code:8][seq:32@bit8] |
| probe：--iters 0 除零/越界、cudaMalloc 不查、midcheck 溢出 inf 后空转 | 三处守卫 + it+1<60 截止 |
| selftest RSS：页大小硬编码 4K、读失败静默 PASS | sysconf(_SC_PAGESIZE) + SIZE_MAX 哨兵 + 显式 FAIL 检查 |
| CpuDevice 死字段 x_/bytes_；Link::sent_seq 无消费者 | 删除 / 注明诊断遗留 |
| ar2.h 注释：defaults 假称读 env（AR2_BACKEND 无通路）、FATAL 语义、finalize 顺序/并发约束、gid_index 0 语义 | 全部按实现修正 |

## 五、审计 A 协议不变式判定表（修复后）

| 不变式 | 判定 |
|---|---|
| 1 槽复用安全（4 方向因果链） | **成立**（F1 修复后；链推导见其报告，全部门铃/CQE 闭合） |
| 2 seq 对齐（engine ≡ claim） | 成立（M1/M2/回退/混用全覆盖；仅失败终端态发散，属良性诊断残留） |
| 3 有界偏斜界 | 成立；**补注**：单流串行使 d==seq+1 分支实际不可达（skew=0 印证），容忍为防御深度 |
| 4 三方内存序 | 成立（F1 修复后；dev_err 自包含无前置序需求） |
| 5 abort 竞态 | 成立（F2 修复后无假成功窗口；双重发送幂等无害） |
| 6 2-WR 链/CQE 记账 | 成立（inline ≤64B 含等号上限合法；wr_id 每链 CQ 唯一无残留） |
| 7 layer 严格等待无误报 | 成立（producer 超前被 send_done 依赖链锁在 expect 内） |
| 8 CPU 镜像语义 | 成立（逐拍对齐，send_done 方向一致） |

## 六、审计 C 文档修正清单（20 条全部落地）

P1：ARCHITECTURE §4 Ar2Ctl 实为 **56B**（非 64B，sizeof 核对；代码注释同步修正）。
P2 ×19：错误码映射笔误（自查）、abort 检查频率、dev_err 位宽、kill 期 REMOTE 机制、
函数计数 12→11、capture/单 op 交互描述、行号去除防漂移、WR 计数口径、"每链独立计数"→
"每 rank 单一计数器"、PITFALLS 引用错位 ×3、__hadd2 4B/迭代、cmake 3.24、selftest A 组
实际口径、NCCL 16K 基线统一 38.8（并连带修正 README/BUILD-TEST 的 16KB 结论为"落后 17%"、
OPEN-ISSUES #1 增补交叉点须实测修正条目）、660→640 op、FATAL 码值、AUDIT-REPORT 悬空引用。

## 七、遗留（转 OPEN-ISSUES 跟踪）

1. **审计修复后的四机 GPU 复跑**（F1 屏障为语义保持性修复，预期无回归，但按纪律需停机窗口实测：
   m1 全尺寸 + layer 3280 op + kill 三件套）。
2. ctrl_poll_abort 8B 部分读理论丢消息（P3；门铃级联双保险在，暂不修）。
3. QP 实际容量未回读校验（P3；目标平台 inline ≥64 实测成立）。
4. finalize 前未强制置 abort 字（P3；违约场景防御，PROTOCOL 已声明契约）。

## 八、结论

- 审计前三路均判定"默认配置下无必然损坏路径"；唯一载荷级缺陷 F1 已修复。
- 交付状态：**代码 0 error 0 warning，selftest 10/10，文档 20 条修正后与代码逐项一致**。
- 交叉验证有效性佐证：A/B 对 F1、gid、回绕、发布定序四项独立得出相同结论；C 抓出的 56B
  布局口径错误同时存在于文档与代码注释——三方视角互补，无单点盲区。

---

# 第二轮审计（2026-09-04 定版轮，任务：V5 正式创建后的全面代码检查）

三独立子代理交叉审计（A 协议与并发 / B 资源错误与构建 / C 注释与文档一致），全部修复并重建验证。

## A 组（协议与并发）
| 编号 | 发现 | 级别 | 修复 |
|---|---|---|---|
| A1 | fence deadline 记账不对称：rank0 逐 fd 各 10s（最坏 30s）vs worker 固定 10s → >10s 触发错位下产生"部分 rank 武装、部分 ArmDead"——恰是栅栏要根除的失配 | WARN | rank0 收集改**单一共享 deadline** + 失败广播 'N' 对称快速失败；worker 等待窗口 = 10s×world；abort 轮询加 8B 帧分级缓冲（顺带根治 TCP 分段部分读丢字节） |
| A2 | 锁存状态机边界（magic static/捕获查询失败方向/触发点 rank 一致性/fence 无死锁） | PASS | — |
| A3 | engine_wait(done) 失败与 kernel "[通过 waitB→写回]" 微秒窗口并发：kernel 正确写回后 op 仍报失败 → 原生重做读已归约输入 → 2Σ 静默错误 | WARN | 新增 `done_wait()`：done 等待失败后 100ms 有界宽限复查，已发布即按成功 |
| A4 | wait_two 模 2^32 差比较边界（回绕/超前/0 值歧义） | PASS | — |
| A5 | 失败语义穷举（各路径自洽 + op 失败后邻 rank 毫秒级收敛全原生） | PASS | 备注 ii 落实：hook 侧 crossover 钳制 ≤65536（AR2_SMAX 默认），防 env 脚枪误判会话失败 |
| A6 | group 计数一致性（独立调用 depth==0 恒可分发；漂移最坏代价=一次性降级） | PASS | — |

## B 组（资源/错误/构建）
| 编号 | 发现 | 级别 | 修复 |
|---|---|---|---|
| B1-W1 | CPU 后端 arena 半失败泄漏（Link 建立失败时 arenaA/B 无登记） | WARN | CpuDevice 增加 arenas 登记向量（与 CUDA 对称），析构兜底释放 |
| B1-W2 | 设备工厂裸 new 穿越 extern "C" 边界（bad_alloc→terminate） | WARN | `new (std::nothrow)` ×2 |
| B1-W3 | CudaDevice 构造忽略 cudaStreamCreateWithFlags 返回值 | WARN | 失败置空并注释降级语义 |
| B2 | fence 字节可被 ctrl_poll_abort 误吞（recv 8B 但只有 1B 到达即丢弃） | WARN | 与 A1 同根因，poll 分级缓冲修复；send 超时码语义注释化 |
| B3 | CMake arch 兜底失效（enable_language 预填 cache=75，守卫永不触发→sm_75） | WARN | `set(CMAKE_CUDA_ARCHITECTURES 120 CACHE STRING "" FORCE)` |
| B4 | **crossover 双默认分叉：hook 8192 vs 库 AR2_CROSSOVER_DEFAULT 32768**（selftest 还按 32K 断言） | **FAIL** | 统一 8192（实测定界），selftest 断言改 8K |
| B5 | tools 期望值/返回码 | PASS | probe smax 魔数与 AR2_MAX_LAYER_OPS 重复定义补联动注释 |
| B6 | GroupStart 失败不回滚 depth / GroupSimulateEnd 泄漏 depth | WARN | 内部调用成功后再计数；SimulateEnd 补递减 |

## C 组（注释/文档）
| 编号 | 发现 | 处置 |
|---|---|---|
| C1 | API.md 缺 ar2_arm_fence / ar2_allreduce_stream / ar2_init_env / V5 env 表；函数计数 11→14 | 已补全 |
| C2 | crossover 双默认未收敛 + "接 tuner" 过期表述 | 已统一 8192 + 改 hook 表述 |
| C3 | ERROR-MODEL 缺 V5 降级/fence-arm 语义；-9 口径未同步 | 已补 §7 + 修正 -9 行 |
| C4 | ARCHITECTURE 缺 hook 分层与 fence-arm 时序 | 已补 §11 |
| C5 | BUILD-TEST 最终 md5/命令 | 一致（本轮后已更新为新 md5） |
| C6 | README 头部"启动基线/tuner"过期、11 函数 | 已刷新 |
| C7 | AUDIT-REPORT 缺工程债修复轮记录 | 本节即补 + 工程债 #1~#5 摘要见 collectives.cc 注释与 E2E-REPORT §2 |
| C8 | PROTOCOL 缺"落后1 自旋"显式分支 | 已补（含模 2^32 差口径） |
| C9 | E2E §5 数值与 results/ 日志 | 逐位一致 |
| C10 | 命名约定裸用 v6/V5 十余处 | 已清理（历史报告按约定豁免） |

## 注释补全清单（本轮落实）
allreduce_one 函数级五拍注释、link_setup QP 容量依据、link_connect QP 参数与 PROTOCOL §2 互链、
capture_layer 旧 gexec 销毁原因 + ThreadLocal 模式理由、CpuDevice env 优先级、probe smax/宏联动、
ar2.h DEV0/1 "必填/默认" 矛盾修正、collectives.cc 条件⑥与实测#1 的 v1/v2 规则残留文案更新。

## 重建与验证
- libar2.so.1.0.0 = `343bea89`、libnccl.so.2.30.7 = `36c26ab6`（四机 ~/v5libs/ 一致）
- CPU selftest 10/10 PASS（含 8K crossover 新断言）；GPU 侧验证由 V5 生产镜像换镜像窗口承担
