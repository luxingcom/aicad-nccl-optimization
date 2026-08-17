# Stage A 回查决策：Channel 日志真实宿主定位与 hook 挂载点定案

**日期:** 2026-08-16
**作者:** Archi（系统架构师）
**性质:** 源码级反汇编回查（只读，不改生产）
**输入:** Stage A 实测现象（主理人执行）/ ADR-015 S1.5-S1.8 / S1 插件阻断报告 / findings-raw 环境数据

---

## 0. TL;DR

**反汇编定案：netDev 真实设置点就在 `sendSetup`/`recvSetup` 内（net.cc L310/L358 的 `ncclTopoGetNetDev` → `req.netDev`），hook 挂载位置正确（L330/L380，位于 Channel 日志之前）。0d83f945 中 `netTransport` 结构体明确指向带 hook 副本且 hook 必执行。**

Stage A 实测"hook 0 条 + Channel 日志自由轮换"与 0d83f945 二进制反汇编**直接矛盾**。二者不可同时成立。**唯一合理解释：Stage A 四机测试实际加载的库不是 0d83f945**（LD_PRELOAD/容器库覆盖/Step 0 库残留等测试环境问题），而非 hook 位置错误。

**推荐路径：不选 b（不迁移 hook 到 ncclTopoGetNetDev），不选 c（不暂缓）。先做库加载核验（验证 Stage A 测试实际加载 .so 的 md5），再重测。**

---

## 1. 反汇编证据链（0d83f945 = Stage A 库）

### 1.1 netTransport 结构体指向带 hook 副本（关键证据）

`netTransport` @ 0x230be88（aarch64 LE）：

```
230be88: 4e455400 00000000   name[8] = "NET"
230be90: 20f31500 00000000   canConnect = 0x15f320
230be98: 60031600 00000000   send.setup  = 0x160360  ← sendSetup#2（带 hook）
230bea0: 903f1600 00000000   send.connect
230bea8: 20ed1500 00000000   send.free
230bee8: 20fd1500 00000000   recv.setup  = 0x15fd20  ← recvSetup#2（带 hook）
```

`ncclTransports` 数组 @ 0x23036b0 → 第 3 项 = 0x230be88 (netTransport)。运行时经 `transportComm->setup()`（transport.cc L34）调用。

### 1.2 Channel 日志字符串宿主（选项 a 的定位结果）

- `Channel %02d/%d : ... [receive] via NET/%s/%d...` @ 0x2f6290 → 引用点 0x160280 在 **recvSetup#2 (0x15fd20)** 内
- `Channel %02d/%d : ... [send] via NET/%s/%d...` @ 0x2f62d8 → 引用点 0x160988 在 **sendSetup#2 (0x160360)** 内

**即：Channel 日志 30 条 = sendSetup#2 + recvSetup#2 执行产生的日志。日志宿主就是带 hook 的两个函数。**

### 1.3 hook 调用存在且必执行

- sendSetup#2: 0x160518 范围检查 `(rank|peerRank)<=3` → 0x160520 `bl 15f424`（ncclRingDevOverride）→ 跳回主流程 → 之后 0x160988 打印 send 日志
- recvSetup#2: 0x15fec8 `bl 15f424` → 之后 0x160280 打印 receive 日志
- hook 本体 0x15f424 完整：map 表读取（CSWTCH @ 0x323000+0x3a0）、pair[0]/pair[1] 判断、RING-ONLY v4 日志（引用 0x2f6150）、`str w20,[x19]`（*dev 覆盖）
- 范围检查读取：w0=[comm+0x1206F0]（**comm->rank，已用 commAlloc str w3,[x22,#1776] 交叉验证偏移正确**）、w1=[x25]（peerInfo->rank，ncclPeerInfo 首字段）
- 四机 rank 0..3 → `(rank|peerRank)<=3` 恒成立 → **hook 必执行**

### 1.4 生产 v3 交叉验证（决定性对照）

生产 v3 库（b7784b49）反汇编：
- `netTransport` @ 0x20fadc8 → send.setup = **0x1591e0（sendSetup#2）**
- sendSetup#2 内 0x1592b4 `bl 1573c4`（ncclIbPeerHcaOverride）
- 且 **v3 运行时 32 条 RING-ONLY v3 日志出现 + 双 dev 轮换完美**（ADR-015 已实证）

**结论：v3 证明 `sendSetup`/`recvSetup` 就是运行时路径，override 在 sendSetup/recvSetup 内执行且生效。0d83f945 采用完全相同的挂载结构（netTransport → sendSetup#2 → hook），机制正确。**

---

## 2. Stage A 实测矛盾分析

| 事实 | 来源 | 含义 |
|---|---|---|
| netTransport.send.setup = 0x160360（带 hook） | 反汇编 | 结构体指向 hook 副本 |
| 0x160360 内 0x160520 调用 hook | 反汇编 | hook 在 Channel 日志（0x160988）**之前** |
| hook 必执行（范围检查恒真） | 反汇编 | 若 sendSetup#2 运行，hook 必触发 |
| RING-ONLY v4 日志 0 条 | Stage A 实测 | hook 未执行 |
| Channel 日志 30 条、dev 自由轮换 | Stage A 实测 | sendSetup#2/recvSetup#2 运行但 req.netDev 未被覆盖 |

**矛盾**：若运行时加载 0d83f945 且走 netTransport，则 Channel 日志出现 ⇒ sendSetup#2 运行 ⇒ hook 必执行 ⇒ RING-ONLY v4 必出现且 Channel dev 必显示覆盖值。实测相反。

**唯一自洽解释**：Stage A 四机测试加载的 .so ≠ 0d83f945（可能 LD_PRELOAD 指到 /opt/nccl-ringonly（生产 v3）或 /opt/nccl-tuner-plugin/lib 或容器自带 stock 库，或 Step 0 库残留未替换）。加载物无 hook ⇒ 0 条 RING-ONLY v4 + 自由轮换完全吻合。

> 佐证：01 上 nccltune-* 容器 LD_PRELOAD 均指向 /opt/nccl-ringonly/libnccl.so.2（生产 v3 库，md5 b7784b49）或 /opt/nccl-tuner-plugin/lib（md5 fe5b6c88），**无一是 0d83f945**。若 Stage A 复用了这些容器而未改 LD_PRELOAD，即复现实测现象。

---

## 3. 决策

### 不选 b：hook 不迁移到 ncclTopoGetNetDev 内部

反汇编已证明当前挂载点（sendSetup/recvSetup 内）就是 netDev 运行时设置点，且 v3 实证此路径生效。迁移理由不成立，且会引入：
- 签名无 peerRank（无法按 peer 映射）→ 需改核心函数签名
- ncclTopoGetNetDev 被 collnet/nvls/pxn 等多路径共用，风险高（S1.6 已否决，维持）

### 不选 c：tuner 优化线不暂缓

Stage A 的问题根因不是架构/代码，而是测试加载库疑点。MAX_CH16 收益已兑现；小消息 LL 的 -28~34% 收益尚未验证但不受此影响。暂缓会丢失进度且掩盖真实问题。

### 推荐：先库加载核验，再重测

1. **核验 Stage A 测试实际加载的 .so**：
   - 四机测试脚本/命令中 `LD_PRELOAD` 是否显式指向 `/tmp/nccl-r14-test/libnccl.so.2.30.7`（0d83f945）
   - 容器内 `LD_LIBRARY_PATH` 是否有优先级更高的 libnccl
   - 启动时在测试进程内打印 `md5sum /proc/<pid>/maps | grep libnccl`
2. **若核验确认加载非 0d83f945** → 修正 LD_PRELOAD 重跑四机，预期 hook 生效、Channel dev 变双 dev 轮换（对齐 v3 模式）
3. **若确认加载确为 0d83f945 且 hook 仍 0 条**（概率极低，与反汇编矛盾）→ 才进入深度排查（在运行时对 sendSetup#2 设断点/单步）

### 兜底升级条件

若重测仍失败，且排除加载问题，才考虑：
- 全量 v3 源码重建专项（S1.7 已备）——以 0d83f945 为权威源，行为基准 = 生产 v3 二进制

---

## 4. 影响

- **变容易**：问题从"代码架构错误"降级为"测试加载核验"，修复成本≈0；hook 挂载点已获源码级确认，后续 Stage A/B 可在同一干净源上继续
- **变困难**：Stage A 测试流程需增加"加载库 md5 断言"关卡（防止再次出现库不一致）
- **需重新审视**：S1.8"recvSetup 是运行时路径"结论**成立**（被 v3 反汇编 + 0d83f945 反汇编双重确认）；但 Stage A 实测现象不能作为否定该结论的证据，因其加载库存疑

---

## 5. 证据文件

- 0d83f945 反汇编：/tmp/nccl-official-2307/build/lib/libnccl.so.2.30.7
- 生产 v3 反汇编：/opt/nccl-ringonly/libnccl.so.2.30.7 (b7784b49)
- Stage A 库测试副本：/tmp/nccl-r14-test/libnccl.so.2.30.7（md5 = 0d83f945）
- 关键字符串偏移：RING-ONLY v4 @ 0x2f6150；receive log @ 0x2f6290；send log @ 0x2f62d8
