# SPCX 场景容器验证计划 — PerSizeTuner 双分支加固（stageB-hardened-two-branch）

日期：2026-08-16
作者：sre-engineer (Rex)
状态：**待生产窗口执行**（当前生产 vllm-tp4-rank0 占用 GPU；四机 bench 需停机窗口，
待 testing-expert 两项测试结束后由 team-lead 统一安排）

## 背景与目标

PerSizeTuner 加固后，per-size cost 覆盖逻辑在 `ncclGetAlgoInfo` 的 **if 分支
（comm->tuner != NULL，SPCX tuner 存在）与 else 分支（comm->tuner == NULL）都生效**，
消除对 `NCCL_NET_PLUGIN=none` 的隐式依赖。

本计划验证：**当外部 tuner 插件存在（模拟 SPCX 劫持，走 if 分支）时，PerSizeTuner
仍强制 allreduce ≤40KB→LL、>40KB→Simple**，即加固生效。

## 验证原理（关键）

- NCCL tuner 插件加载（`src/plugin/tuner.cc`）：
  - `NCCL_TUNER_PLUGIN=<path>` 显式指定 tuner .so（导出 `ncclTunerPlugin_v6` 符号）→ `comm->tuner != NULL` → **if 分支**
  - 不设置 / `NCCL_TUNER_PLUGIN=none` / `NCCL_NET_PLUGIN=none` → `comm->tuner == NULL` → **else 分支**
- 生产当前为 `NCCL_NET_PLUGIN=none` → else 分支。为验证 if 分支，用
  `NCCL_TUNER_PLUGIN=/path/spcx_stub_tuner.so` 强制加载一个"敌对" tuner stub。
- stub 故意给出**与 per-size 策略相反**的 cost table（偏好 LL128/Simple，LL 打 5.0），
  若加固生效，最终协议仍应被强制为 LL（≤40KB）/ Simple（>40KB）；
  若加固失效（回归到旧的 else-only 行为），协议会被 stub 带偏（LL128），可被
  `NCCL_TUNER_DEBUG=1` 的 PerSizeTuner 日志 + 实际协议观察到。

## 验证素材（本任务已交付）

1. stub tuner 源码：`spcx_stub_tuner.c`（本仓库工作区 / 归档目录）
   - 编译：`gcc -shared -fPIC -O2 -o spcx_stub_tuner.so spcx_stub_tuner.c -I<src>/src/include -I<src>/build/include`
2. 加固库：`build/lib/libnccl.so.2.30.7`（md5 见 MD5-RECORD.txt）
3. NCCL 官方测试：仓库自带 `build/test/all_reduce_perf`（随 `make src.build` 产出）

## 执行步骤（窗口期内，四机）

### A. 基础回归（无 SPCX，等价生产场景）
```shell
# 每节点容器内，以 LD_PRELOAD 加载加固库；NCCL_NET_PLUGIN=none（与生产一致）
export NCCL_LIBRARY=/path/build/lib/libnccl.so.2.30.7
export LD_PRELOAD=$NCCL_LIBRARY
export NCCL_ALGO=RING
export NCCL_NET_PLUGIN=none
export NCCL_TUNER_DEBUG=1
# 判据（与 StageB 3d9cf539 基线一致）：
#   - 小消息 allreduce(<=40KB) LL 收益 19-27% 保持
#   - 368KB 持平
#   - 无 NCCL 错误码 110
mpirun -np 4 ... ./build/test/all_reduce_perf -b 8 -e 524288 -f 2 -g 1 -n 100
```

### B. SPCX 劫持场景（本次加固的核心验证）
```shell
# 在 A 基础上，额外设置 NCCL_TUNER_PLUGIN 指向 stub（模拟 SPCX tuner 存在，走 if 分支）
export NCCL_TUNER_PLUGIN=/path/spcx_stub_tuner.so
export NCCL_NET_PLUGIN=none   # 保持 net 层不变；仅 tuner 层被 stub 劫持
mpirun -np 4 ... ./build/test/all_reduce_perf -b 8 -e 524288 -f 2 -g 1 -n 100
# 判据：
#   1) 日志出现 "Successfully loaded external tuner plugin spcx-stub-sim"
#      → 确认 comm->tuner != NULL，确实走 if 分支
#   2) NCCL_TUNER_DEBUG=1 日志出现 "PerSizeTuner: allreduce nBytes=... -> LL/Simple"
#      → 确认加固覆盖在 if 分支执行
#   3) 小消息性能仍呈 LL 特征（19-27% 相对基线提升），368KB 持平 → 加固端到端生效
#   4) 反向验证（可选）：注释掉加固后同一命令应出现 LL128 特征 → 证明覆盖确实来自加固
```

### C. 对照（证明非误判）
- 用 `NCCL_TUNER_PLUGIN=/path/spcx_stub_tuner.so` + **未加固库**（3d9cf539 或旧 build）
  复跑 B 步骤 → 预期协议被带偏为 LL128、无 PerSizeTuner 日志 → 证明 A/B 差异来自加固。

## 时间与资源

- 需四机空闲窗口（约 30-60 分钟），每节点 4 GPU（TP4）。
- 优先级：在 testing-expert（Tessa）两项遗留测试完成后，由 team-lead 统一排期。
- 执行人：sre-engineer 主导，testing-expert 可协助比对 Tessa 基线。

## 结果记录模板

| 场景 | lib md5 | NCCL_TUNER_PLUGIN | ≤40KB proto | >40KB proto | LL 收益 | 368KB | err 110 | 结论 |
|---|---|---|---|---|---|---|---|---|
| A 基线回归 | <加固md5> | (none) | LL | Simple | 19-27% | 持平 | 无 | PASS/FAIL |
| B SPCX劫持 | <加固md5> | spcx_stub_tuner.so | LL | Simple | 19-27% | 持平 | 无 | PASS/FAIL |
| C 对照(未加固) | 3d9cf539 | spcx_stub_tuner.so | LL128(预期) | LL128/Simple | - | - | - | 预期被带偏 |
