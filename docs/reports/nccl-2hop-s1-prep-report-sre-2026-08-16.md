# NCCL 2-hop kernel · S1 前哨验证报告（Rex / SRE）

**日期**: 2026-08-16
**性质**: S1 三验证项（步结构模拟 / CUDA graph 兼容 / 368KB 阈值定标）
**状态**: 准备完成，等待四机停机窗口执行

---

## 0. 准备阶段完成情况（已就绪）

| 项 | 状态 | 说明 |
|---|---|---|
| 算法数学验证（单机 mock） | ✅ | 纯 Python + 线程/mailbox 传输模拟 4 rank；**2-hop RS(2)+AG(2) 与 ring RS(3)+AG(3) 均在 16/64/256/4096/65536 元素下输出 = sum(ranks)，全部通过** |
| 多机 bench 脚本 | ✅ | `twohop_bench.py`（8 尺寸 × ring_real/ring_manual/2hop + 每步分解 + 正确性） |
| CUDA graph 脚本 | ✅ | `cudagraph_test.py`（Test A 顺序 all_reduce 批 1/8/16/32/64；Test B 双 PG+双 stream 双边并发；Test C 64 档全捕获） |
| 容器启动脚本 | ✅ | `start_2hop.sh`（复用已验证基线模板 + 逐机 PEER_HCA） |
| 编排脚本 | ✅ | `run_2hop_bench.sh` / `push_and_setup.sh` |
| 4 测试容器 | ✅ | `2hop-s1-rank0..3` 已启动（sleep 驻留，0 GPU 计算） |
| libnccl.so.2 符号链接 | ✅ | 四机容器 `/usr/lib/aarch64-linux-gnu/libnccl.so.2 -> libnccl.so.2.30.7` |
| ring-only 库加载 | ✅ | LD_PRELOAD `/opt/nccl-ringonly/libnccl.so.2.30.7` 四机 maps 确认（非系统库） |
| 关键 env | ✅ | NCCL_ALGO=RING、逐机 PEER_HCA、MAX_NCH=16、IB_HCA 4 dev、NET=IB、NET_PLUGIN=none |

## 1. 2-hop 算法定案（mock 已验证）

4 网络步 = RS(2 步) + AG(2 步)：
- **RS 步1（双边并发）**: rank r 右发 [c_{r+1}, c_{r+2}]、左发 c_{r-1}；同时收右 c_r、收左 [c_r, c_{r+1}]；归约 x[r]；carry = c_{r+1}(R_{r-1})
- **RS 步2（转发）**: 右发 carry → r+1；收左 c_r 转发 → x[r] 完全归约
- **AG 步3（双边并发）**: 把完全归约 c_r 双向扩散；收右 c_{r+1}*、左 c_{r-1}*
- **AG 步4（转发）**: 左发 fwd(c_{r+1}*)；收右 c_{r+2}* → 全量补全

> 注：步1/步3 为双边并发（2 边同时收发），步2/步4 为单边转发（对边贡献必须走 2 跳的固有约束）。
> 每 rank 收发总量 ≈ 1.75S（RS 步1 3chunk + 步2 1chunk；AG 步3 2chunk + 步4 1chunk），
> 高于 ring 的 1.5S —— 印证设计「大消息带宽受限、只路由 ≤512KB」。

**补充变体（对齐 team-lead 配对指令 "step1 0↔1‖2↔3、step2 1↔2‖3↔0"）**：
- **pairwise-exchange**: 2 步全量交换归约（步1 对 (0,1),(2,3)；步2 对 (1,2),(3,0)），每 rank 收发 2S —— 作为激进下限数据点
- 三算法（2hop / ring / pair）均在 16/64/256/4096/65536 元素 mock 验证通过

## 2. 待执行（等窗口）

- **验证项1 步结构模拟**: 8 尺寸 × ring_real/ring_manual(6步)/2hop(4步)，输出每尺寸总延迟 + 每步分解
  判定: 2-hop 总延迟 ≤ ring×0.7 且 L'≈L（步延迟差 ≤10%）
- **验证项2 CUDA graph**: Test A/B/C（1/8/16/32/64 档 + 64 全捕获）
  判定: 捕获成功 + 重放正确 = 兼容；失败记录失败模式（S1 最大风险点）
- **验证项3 368KB 阈值**: 256/368/512KB × LL vs Simple vs 2-hop，输出最优路由
- 每协议（auto/LL/Simple）跑一轮 bench；正确性全检

## 3. 窗口需求

- **预计时长**: 30 分钟（3 协议 × ~1min bench + CUDA graph ~3min + NCCL init/连接建立 + 调试余量）
- **建议**: 生产 vLLM 四容器停机（或最低限 quiesce 网络），避免 RDMA 干扰影响延迟定标
- **不触碰**: 生产库 2be94172、生产容器 env、/opt/aicad-prod

## 4. 窗口内执行命令（turnkey，已在 <node1> 验证编排机制）

```bash
# 在 <node1> 上执行（run_2hop_bench.sh 的 rank0 分支假设本机为 rank0 主机）：
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench"              # auto 协议
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench NCCL_PROTO=LL"
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh bench NCCL_PROTO=Simple"
ssh <node1> "bash /opt/2hop-s1/run_2hop_bench.sh cudagraph"
# 产物: /opt/2hop-s1/out/*.log
```

## 5. 历史教训规避

- **不用外部 tuner 插件**（历史 S1 证明插件破坏 ring-only net 连接）→ 本 S1 只用 ring-only 库 + 显式 NCCL_PROTO
- **测试容器必须带 libnccl.so.2 符号链接** → 已确认
- **逐机 PEER_HCA 不同** → 已按 rank 配置

---
产物: /opt/2hop-s1/（remote）+ deliverables/engineering-assurance/（本地）
