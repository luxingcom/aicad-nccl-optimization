# MAX_NCHANNELS=16 生产 AB —— 停机窗口 SOP + 大档补测报告（SRE Rex）

**日期**：2026-08-16 18:00 (UTC+8)
**角色**：SRE 工程保障（Rex）
**目标**：为生产 `NCCL_MAX_NCHANNELS=16` 真实 AB 测试提供（1）放行前置大档补测（2）补丁预案（3）停机窗口 SOP（4）AB 执行流程
**前置结论**：✅ 大档补测通过（16MB+ 无实质劣化）→ 可进入停机窗口 AB

---

## 0. 前置盘点（当前状态，已核实）

| 项 | 状态 |
|---|---|
| 生产 vLLM | 四机 vllm-tp4 手动容器运行中（healthy），8001 HTTP 200 |
| systemd | vllm-tp4-head/worker 四机 **inactive**，monitor **未运行**（pgrep 无命中） |
| 容器 env（docker inspect rank0） | T1aM4 终态已注入：`MIN_CH=4 / PROTO=Simple / BUFFSIZE=8388608`，**无 MAX_NCHANNELS** |
| 生产脚本 | head(01) md5=`92e5fc4c...304a`；worker(02)=`6148617c...1ce4`、worker(03/04)=`28071f0d...9ba6` |
| 测试载体 | sglang:26.07 容器 + /opt/nccl-ringonly + /tmp/nccl_scan_large.py 四机就绪（已清理） |

### ⚠️ 回滚锚点风险（重要）
- `.bak-ncclT1aM4-20260816`（四机）为 **过期快照**：与当前脚本 diff = `MIN_CH 2→4` + 新增 `PROTO=Simple` + `BUFFSIZE=8388608`（即 T1aM4 中间态，缺 16:24 引号修复 `fix_env_quotes.py`）。
- **不要**用 `.bak-ncclT1aM4` 回滚 MAXCH16（会丢失 T1aM4 终态 + 引号修复）。
- **正确回滚锚点** = 应用补丁时新建的 `.bak-ncclMAXCH16-20260816`（其内容 = 当前 T1aM4 终态）。
- 已同时保留 `.bak-ncclT1aM4`（作为历史对照，不用于本次回滚）。

---

## 1. 大消息档补测结果（放行依据）

**方法**：sglang 容器 + ring-only，sizes=2M/4M/8M/16M/32M/64M float32，warmup10+100 次，BASE(T1aM4) vs MAX_CH16 各复跑 2 次。纯容器测试（MASTER_PORT 25998），生产 8001 全程 healthy。

| size | BASE avg µs | MAX16 avg µs | Δlatency | BASE busbw | MAX16 busbw | Δbusbw | 判定 |
|---|---|---|---|---|---|---|---|
| 2M | 1012 | 299 | **-70.4%** | 3.12 | 10.52 | +238% | 大幅改善 |
| 4M | 658 | 346 | **-47.5%** | 9.56 | 18.21 | +90% | 大幅改善 |
| 8M | 759 | 597 | **-21.4%** | 16.58 | 21.09 | +27% | 明显改善 |
| 16M | 1162 | 1089 | **-6.2%** | 21.66 | 23.10 | +6.6% | 改善 |
| 32M | 2238 | 2165 | **-3.3%** | 22.49 | 23.25 | +3.4% | 改善 |
| 64M | 4476 | 4645 | **+3.8%** | 22.50 | 21.67 | -3.7% | ⚠️ 轻微（~170µs/4.5ms，边际） |

**结论（Archi 关注点）**：16MB+ **无实质劣化**。16M/32M 明确改善；64M 轻微 +3.8%（绝对 ~170µs，两次复跑方向一致但在边际区间）。64M 远超生产实际消息规模（生产主档 368KB -58%、1MB -54%，vLLM seqs=6/btok=4096 下不会出现 64M allreduce）。**MAX_CH16 放行生产 AB，风险可控。**
详细数据：`deliverables/engineering-assurance/nccl-maxch16-large-msg-2026-08-16.md`

---

## 2. MAX_CH16 生产补丁（四机精确 diff + md5）

**补丁内容**：在 `start_tp4_head.sh`(01) / `start_tp4_worker.sh`(02/03/04) 的 `NCCL_BUFFSIZE=8388608` 行后追加一行：
```diff
   -e 'NCCL_BUFFSIZE=8388608'
+  -e 'NCCL_MAX_NCHANNELS=16'
   -e 'NCCL_SET_THREAD_NAME=1'
```

**精确 diff（已在临时文件实测）**：
- 01 head：`108a109 > -e 'NCCL_MAX_NCHANNELS=16'`
- 02/03/04 worker：`113a114 > -e 'NCCL_MAX_NCHANNELS=16'`

**md5 对照（补丁前后）**：
| 机 | 脚本 | current md5 | patched md5 |
|---|---|---|---|
| 01 | start_tp4_head.sh | `92e5fc4c870bc2a3f8ae60a0a7be304a` | `d17b9dd612636c4cf78f82553989d59c` |
| 02 | start_tp4_worker.sh | `6148617cbc86a9a15e03c477010a1ce4` | `4f022acf6e8269fd2d6e136b6fbbdd7a` |
| 03 | start_tp4_worker.sh | `28071f0de253e525e4b453d38c9b9ba6` | `8faccfb72386186425bc717e8cb48e1a` |
| 04 | start_tp4_worker.sh | `28071f0de253e525e4b453d38c9b9ba6` | `8faccfb72386186425bc717e8cb48e1a` |

**校验**：四机 PATCHSIM 版 `check_vllm_script.sh` 均 ✅ 通过（语法/无注释吞续行/无尾随空格/SERVE_CMD/HOME）。

---

## 3. 停机窗口 SOP（可直接执行）

> 当前 systemd inactive + monitor 未运行 ⇒ **停机必须用 `docker rm -f` 杀手动容器**（`systemctl stop` 对手动容器无效，仅作防抢跑保险）。启动走 **systemd**（拉起 monitor 后用补丁脚本重建容器）。

### 3.1 停机（预计 2-3 分钟）
```bash
# ① 保险：全部 systemctl stop（inactive 状态下为 no-op，防 monitor 抢跑）
for h in <node1> <node2> <node3> <node4>; do
  ssh $h "echo 'AS12<REDACTED>' | sudo -S systemctl stop vllm-tp4-head.service vllm-tp4-worker.service 2>/dev/null"
done
# ② 停 worker 先（03→04→02），head 后（01）——环序逆序，减 TCPStore 撕裂
ssh <node3> "docker rm -f vllm-tp4-rank3"; sleep 2
ssh <node4> "docker rm -f vllm-tp4-rank2"; sleep 2
ssh <node2> "docker rm -f vllm-tp4-rank1"; sleep 2
ssh <node1> "docker rm -f vllm-tp4-rank0"; sleep 2
# ③ 确认全停（期望 4 机均无输出 / 空）
for h in <node1> <node2> <node3> <node4>; do
  ssh $h "docker ps -a --filter name=vllm-tp4-rank --format '{{.Names}} {{.Status}}'"
done
```

### 3.2 应用补丁（预计 2 分钟；每机：备份→sed→md5 校验→check）
```bash
# 对 01（head）
ssh <node1> '
  cp /opt/aicad-prod/scripts/start_tp4_head.sh /opt/aicad-prod/scripts/start_tp4_head.sh.bak-ncclMAXCH16-20260816
  sed -i "/NCCL_BUFFSIZE=8388608/a\  -e '\''NCCL_MAX_NCHANNELS=16'\''" /opt/aicad-prod/scripts/start_tp4_head.sh
  md5sum /opt/aicad-prod/scripts/start_tp4_head.sh   # 期望 d17b9dd6...
  bash /opt/aicad-prod/scripts/check_vllm_script.sh /opt/aicad-prod/scripts/start_tp4_head.sh
'
# 对 02/03/04（worker）
for h in <node2> <node3> <node4>; do
  ssh $h '
    cp /opt/aicad-prod/scripts/start_tp4_worker.sh /opt/aicad-prod/scripts/start_tp4_worker.sh.bak-ncclMAXCH16-20260816
    sed -i "/NCCL_BUFFSIZE=8388608/a\  -e '\''NCCL_MAX_NCHANNELS=16'\''" /opt/aicad-prod/scripts/start_tp4_worker.sh
    md5sum /opt/aicad-prod/scripts/start_tp4_worker.sh   # 02 期望 4f022acf...；03/04 期望 8faccfb7...
    bash /opt/aicad-prod/scripts/check_vllm_script.sh /opt/aicad-prod/scripts/start_tp4_worker.sh
  '
done
```

### 3.3 启动（worker 先起 → head 后起；预计 head 冷启动 ≤15min）
```bash
# ① worker 先起（systemd 拉起 monitor；head 未起时 monitor 会等 head TCPStore ≤120s 循环重试，属设计行为）
for h in <node2> <node4> <node3>; do
  ssh $h "echo 'AS12<REDACTED>' | sudo -S systemctl start vllm-tp4-worker.service 2>/dev/null"
done
sleep 3
# ② head 后起（head monitor 启动时先清 worker 容器→起 head→TCPStore 就绪→worker monitor 过门禁重建，系统设计 cold-start 路径）
ssh <node1> "echo 'AS12<REDACTED>' | sudo -S systemctl start vllm-tp4-head.service 2>/dev/null"
```

### 3.4 健康确认（预计 8-15 分钟，权重加载）
```bash
# ① 等 head 就绪日志
ssh <node1> 'for i in $(seq 1 90); do
  docker logs vllm-tp4-rank0 2>&1 | grep -q "Application startup complete" && { echo "READY ~$((i*10))s"; break; }
  sleep 10; done'
# ② API 健康
ssh <node1> 'curl -s -m 5 -o /dev/null -w "HTTP %{http_code}\n" http://<LAN-IP>:8001/health'   # 期望 200
# ③ 四机容器 healthy
for h in <node1> <node2> <node3> <node4>; do
  ssh $h "docker ps --filter name=vllm-tp4-rank --format '{{.Names}} {{.Status}}'"
done
# ④ 证据：env 注入确认（期望 NCCL_MAX_NCHANNELS=16 出现）
ssh <node1> 'docker inspect vllm-tp4-rank0 --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -E "NCCL_MAX_NCHANNELS|NCCL_BUFFSIZE|NCCL_PROTO|NCCL_MIN_NCHANNELS"'
# ⑤ NCCL 日志确认通道数（期望 Channel 00/16）
ssh <node1> 'docker logs vllm-tp4-rank0 2>&1 | grep -oE "Channel 0[0-9]/[0-9]+" | tail -3'
```

### 3.5 30 分钟观察窗
- 盯 `docker logs vllm-tp4-rank0` 无 NCCL error/timeout/retry 暴增
- 盯 Prometheus（02:8191）：GPU util、无 OOM、无请求错误
- `.77` 客户端业务流量持续时，记录 `num_requests_running` 基线（判读分层用）
- 观察窗内无异常 → **交给 Tessa AB bench**

---

## 4. 回滚 SOP（MAXCH16 → T1aM4）

```bash
# ① 停机（同 3.1）
for h in <node1> <node2> <node3> <node4>; do
  ssh $h "echo 'AS12<REDACTED>' | sudo -S systemctl stop vllm-tp4-head.service vllm-tp4-worker.service 2>/dev/null"
done
ssh <node3> "docker rm -f vllm-tp4-rank3"; ssh <node4> "docker rm -f vllm-tp4-rank2"
ssh <node2> "docker rm -f vllm-tp4-rank1"; ssh <node1> "docker rm -f vllm-tp4-rank0"
# ② 恢复 T1aM4 终态脚本（用本次新建锚点 .bak-ncclMAXCH16，内容 = T1aM4 终态；勿用过期 .bak-ncclT1aM4）
ssh <node1> 'cp /opt/aicad-prod/scripts/start_tp4_head.sh.bak-ncclMAXCH16-20260816 /opt/aicad-prod/scripts/start_tp4_head.sh && md5sum /opt/aicad-prod/scripts/start_tp4_head.sh'  # 期望 92e5fc4c...
for h in <node2> <node3> <node4>; do
  ssh $h 'cp /opt/aicad-prod/scripts/start_tp4_worker.sh.bak-ncclMAXCH16-20260816 /opt/aicad-prod/scripts/start_tp4_worker.sh && md5sum /opt/aicad-prod/scripts/start_tp4_worker.sh'
done
# ③ 启动 + 健康确认（同 3.3/3.4；确认 env 中 MAX_NCHANNELS 消失）
```

---

## 5. AB 执行流程（完整命令序列 + 耗时预估）

| 阶段 | 动作 | 耗时 |
|---|---|---|
| A 前置 | 大档补测（已✅） | 已完 |
| B 停机 | 3.1（stop + rm -f 四机） | ~3 min |
| C 补丁 | 3.2（备份/sed/校验 四机） | ~2 min |
| D 启动 | 3.3（worker 先→head 后） | ~1 min 触发 |
| E 冷启动 | 3.4 权重加载 + READY | 8-15 min |
| F 观察 | 3.5 健康/日志/监控 + env 证据 | 30 min |
| G Tessa AB | Tessa bench（32K c1 主判据 + 131K 视窗，带并发监控） | ~20-30 min |
| H 判读 | PR/DE/TTFT 阈值判读（32K 主判据 / 131K 视窗） | ~10 min |
| I 保留/回滚 | 通过→保留（.bak-ncclMAXCH16 留档）；不通过→第 4 节回滚 | 5 / 25 min |

**判读阈值参考（沿用 T1aM4 窗口口径）**：
- 32K 主判据：PR≥基线、DE 不显著破线、TTFT 不劣化、0 错误
- 131K 视窗：纯净 wave1 判读（.77 流量污染需带 `num_requests_running` 分层）
- MAX_CH16 预期：368KB allreduce -58% → prefill/TTFT 进一步改善；小消息持平；大档无实质退化（本报告 §1）

**保留操作**：确认后仅需归档 `.bak-ncclMAXCH16-20260816`（四机）作为历史，更新 `REFERENCE.md`/runbook。

---

## 6. 风险与注意事项

1. **手动容器 + systemd inactive**：停机必须 `docker rm -f`；`systemctl start` 前必须确保容器已删，否则 monitor 只 `docker wait` 不重建（补丁不生效）。
2. **head 后起**：head monitor 启动时会先清 worker 容器（设计行为）——worker 先起即可，勿同时起 head。
3. **回滚锚点**：本次用 `.bak-ncclMAXCH16`（= T1aM4 终态），**勿用**过期 `.bak-ncclT1aM4`。
4. **补丁仅动 ENV_ARGS 一行**：四机 `check_vllm_script.sh` 已预检通过。
5. **停机窗口期间 embed(03/04 :8022)/litellm(02 :4000) 保留不动**。
6. **AB 判读带并发监控**（T1aM4 窗口教训：R1 污染 DE 39 vs R2 纯净 93.84）。
