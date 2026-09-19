# ADR-016: ring-only per-peer netDev 映射从「库内硬编码」升级为「运行期可配置」（v5 补丁）

**状态:** Accepted
**日期:** 2026-09-19
**作者:** 工程保障团队（依据客户部署实录复盘）
**输入:** 《LuZ-0.1.7 DSV41 TP4 四机环网部署实录》坑1/错误1、`tools/gen_devmap.py` 实测链路、v4 补丁 `patches/v4-netdev-hardcode.patch`（已修复 hunk 行数缺陷）

---

## 背景

ADR-015 将 per-peer netDev 映射硬编码进 NCCL 库（v4 补丁），解决了 env 解析 + hostHash 门控 + 源码漂移三个脆弱点，但也把**物理拓扑焊死进了二进制**：

实录坑1：客户现场接线 F0/F1 整体装反 ⇒ 四机同时 `NCCL unhandled system error` + `ibv_modify_qp 110`。由于映射表在库内，**唯一修复路径只有两条**：①动物理线（最终采用）；②改源码重新编译分发库（重、慢、且现场通常没有构建环境）。

实录错误1还证明了「软修」不存在：调换 `NCCL_IB_HCA` 顺序无法改变配对——库按物理设备名选 dev，ADR-015 那句「dev 编号对应 NCCL_IB_HCA 的 0..3」是**表的编码格式**说明，不是**运行期解析规则**。

同类部署客户反复踩坑的另一面是：环网方案包只发资料不给步骤/工具，接线一变就得重编库，部署门槛极高。

## 选项分析

### A. 维持 v4 硬编码（现状）
- 优点：行为确定。
- 缺点：任何拓扑变化 = 重编库；客户现场不可自助；与「方案包组件化」目标冲突。

### B. 恢复 env 解析机制（ADR-015 之前）
- 缺点：正是 ADR-015 消灭掉的脆弱机制（env 解析 + hostHash 门控），历史已证不可靠。**排除。**

### C.（采纳）v5：内建默认表 + 运行期覆盖
在 v4 基础上叠加运行期覆盖：
- **内建默认表 = v4 生产表逐位一致**（不设任何新 env ⇒ 行为与现生产完全相同，零迁移成本）；
- `NCCL_RING_DEV_MAP`（字符串形态，优先）或 `NCCL_RING_DEV_MAP_FILE`（JSON 文件形态）运行期覆盖；
- 解析失败**不崩**：WARN + 回退内建默认表（fail-safe，通信初始化永不因映射配置失败而中断）；
- 覆盖生效打 INFO（`RING-ONLY v5: per-peer dev map from ...`），每条连接仍打 `RING-ONLY v5 rank..` 行——**可观测性与 v4 同级**；
- dev 索引语义沿用 NCCL_IB_HCA 顺序 0..3；even channel→devA、odd channel→devB 轮换语义不变。

配置产出链路工具化：`tools/probe_ring_topology.sh`（实测）→ `tools/gen_devmap.py`（校验+生成，含环闭合/口用满等 fail-closed 校验）→ env 下发。**人不再手写映射表。**

## 决策

**采用 C。** `patches/v5-netdev-configurable.patch` 自 2026-09-19 起取代 `v4-netdev-hardcode.patch` 成为生产补丁栈一员；v4 补丁保留归档（其内建表即 v5 默认表的行为锚点）。

## 影响

- **变容易**：换拓扑/修接线后**免重编库**，env 下发即可；`gen_devmap.py` 校验器把「表填错」类故障挡在起栈前；客户可自助部署。
- **变困难**：新增两个 env 面（`NCCL_RING_DEV_MAP*`）需纳入 config 基线与 doctor 检查；配置错误回退默认表属 fail-safe 而非 fail-fast——**必须以 doctor/probe 实测闭环，不能只看「没报错」**。
- **兼容性**：`env` 未设时与 v4 逐位一致；v1 环邻过滤 / StageB tuner / 双分支加固 / libncclpin shim 均不受影响。
- **升级路径**：0.27 等未来重编时，v5 补丁直接移植；内建默认表仍是「已知可配行为」的锚点。

## 验证基线（发布前置）

1. 补丁静态自洽：hunk 行数校验通过；对官方 2.30.7-1 `net.cc` 往返应用逐字节一致（已做）。
2. 行为等价：未设 env 时运行期日志与 v4 一致（`RING-ONLY v5 rank ...`，表项与 v4 默认相同）。
3. 覆盖生效：设置 env 后日志出现 `from NCCL_RING_DEV_MAP`，连接配对与生成的表一致（四机 S1 矩阵）。
4. fail-safe：故意给非法 env → WARN + 回退默认表 + 通信正常初始化。
5. 端到端：nccl-tests 全尺寸正确性 + 基线延迟带内 + `tools/doctor.sh` 全绿。

> 注：v5 补丁的**真机编译与四机验证**须在下一个维护窗口执行（本仓库当前不含二进制与真机数据）；发布前生产仍用 v4 库，不受影响。
