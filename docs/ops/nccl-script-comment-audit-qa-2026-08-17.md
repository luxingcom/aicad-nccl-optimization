# 脚本注释引用审计报告（QA / Tessa）

**审计人**：泰莎（Tessa）· 测试专家 | 工程保障团队
**日期**：2026-08-17
**范围**：/opt/aicad-prod/ 全部 .py/.sh、/opt/2hop-s1/ 测试脚本、NCCL 官方源码/补丁归档
**要求**：所有测试工具和脚本必须在代码注释上有引用（注释说明用途 / 归属项目 / 文档位置）

---

## 0. TL;DR

- 盘点 **93 个脚本/补丁文件**（prod 脚本 40 + bench py 2 + v027-test 21 + 2hop 26 + nccl-ab-B 1 + 补丁 3 类）。
- **52 个文件**缺少文档引用注释，本次已全部补充（仅插入注释行，**零逻辑变更**，语法/内容逐文件核验通过）。
- 补丁文件头部已有 AICAD 注释块（含 ADR-014/015 引用），达标。
- 遗留建议：.bak 归档文件与 /tmp 临时脚本不纳入补充范围（见 §5）。

---

## 1. 审计方法

1. 逐文件读取头部（head -8/16）判断是否具备：用途 / 归属项目 / 文档位置 三类引用。
2. 统一标记：有 `# DOCS:` 或 `# 关联文档` 或 docstring 内文档路径 = 达标；否则 = 缺。
3. 对缺失文件用自动化脚本插入注释行（sh 插入 `# DOCS:`/`# 关联文档` 行于头部块末；py 插入注释行或补齐全头）。
4. 验证：`bash -n`（39 个 sh 全过）、`python3 -m py_compile`（13 个 py 全过）、diff 逐文件确认新增行均为注释、原文完整保留（`sed` 行偏移比对）。
5. 所有被改文件备份于服务器 `/opt/aicad-prod/docs/.qa-comment-bak-20260817/`。

---

## 2. 盘点结果

### 2.1 已达标（头部含用途 + 文档引用）

| 类别 | 文件 | 引用 |
|---|---|---|
| 生产启动/编排 | start_tp4_head.sh、start_tp4_cluster.sh、start_tp4_worker_deepgemm.sh、start_tp4_cluster_deepgemm.sh、start_tp4_head_deepgemm.sh、start_tp4_head_marlin.sh、start_tp4_head_marlin_only.sh、start_tp4_head_nvfp4weight.sh、start_tp4_head_nvfp4weight_cutlass.sh、start_v026r_cluster.sh | DOCS: REFERENCE.md / runbook / rollback-anchors 等 |
| 自检/自愈 | check_vllm_script.sh、monitor_tp4_head.sh、start_embed_8022.sh | DOCS: REFERENCE.md / tools-index / self-recovery |
| NCCL 补丁 | backup/nccl-official-2307-*/patches/{v1-ring-only,v4-netdev-hardcode,stageB-tuner-two-band,stageB-hardened-two-branch}.patch、/opt/2hop-s1/2hop-proto-kernel.patch | 文件内 `AICAD custom patch` 注释块 + ADR-014/015 |

### 2.2 已补充（52 个文件，本次）

| 类别 | 数量 | 说明 |
|---|---|---|
| 生产脚本缺 DOCS 行 | 9 | start_tp4_head_b12x/combo/cutlass/overlap、shim-deploy、preflight_sglang、mirror_to_02、start_sglang_tp4_head/worker |
| v027-test 测试脚本 | 21 | 全部补 `# 关联文档: v027-perf-results-2026-08-15.md（归档）` |
| 2hop-s1 顶层脚本 | 4 | run_2hop_bench.sh、run_2hop_s2.sh、run_p0.sh、start_2hop.sh → 归档清单 |
| 2hop-s1 s3 脚本 | 8 | run_s3.sh、s3_isolation.sh、lat_probe.sh、run_gates.sh（全头）、s3_common/s3_g1/s3_g2/s3_g3_ab/merge_g3.py（ref） |
| 2hop-s1 s3 无头 py | 6 | lat_probe.py、mini_ar.py、smoke_nccl.py、mini2/3/4.py → 补齐全头（用途+归档引用） |
| 基准工具 | 2 | bench_v2.py、bench_prefill_decode_async.py → 头部补 关联文档 行 |

**补充格式**（与既有 DOCS 风格统一）：
```
# 关联文档: file:///opt/aicad-prod/deliverables/engineering-assurance/<文档>.md（<说明>）
```

### 2.3 不纳入补充（说明原因）

| 文件 | 原因 |
|---|---|
| 所有 `.bak-*` 归档副本 | 非运行对象；随正式文件保留；清理策略见 governance §3.3 |
| /tmp/annotate_nccl_env.py、/tmp/check_nccl_load.sh | /tmp 一次性临时工具（clean_tmp_logs.sh 清 >30d），建议删除/移入正式目录时再补注释 |
| backup/tp4-20260812/nccl-ringonly-v2.30.7-patch.diff | 历史 v2 快照，ADR-015 已标记"不可用于重建生产" |

---

## 3. 修改明细（示例）

**bench_v2.py**（头部新增）：
```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 关联文档: file:///opt/aicad-prod/deliverables/engineering-assurance/nccl-benchmark-v2-report-qa-2026-08-16.md（v2 基准判读报告）
#          file:///opt/aicad-prod/deliverables/engineering-assurance/nccl-final-performance-baseline-2026-08-17.md（最终性能基线 v1.0）
```

**start_tp4_head_b12x.sh**（头部末新增）：
```bash
# DOCS: file:///opt/aicad-prod/docs/scripts/REFERENCE.md
```

**2hop s3/lat_probe.py**（原无头，补齐全头）：
```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S3 lat_probe: 4.5ms root-cause latency probe（prod lib vs proto lib） — 2-hop S3 测试辅助脚本（项目已 D 收尾归档）。
关联文档: file:///opt/aicad-prod/deliverables/engineering-assurance/nccl-2hop-archive-manifest-v1-architect-2026-08-17.md
"""
```

---

## 4. 验证证据

- `bash -n`：39/39 OK，0 FAIL（含 6 个首轮已改 + 33 个次轮补充）。
- `python3 -m py_compile`：13/13 OK。
- diff 逐文件核对：新增行均为 `#` 注释或 `"""` 文档字符串；无任何可执行代码行变更。
- 预置头文件原文完整性：`sed 1,5d` 后与备份逐一 diff = 完全一致（6/6）。
- 备份：`/opt/aicad-prod/docs/.qa-comment-bak-20260817/`（52 个文件 + file-registry.md）。

---

## 5. 遗留建议（P2，下窗口）

1. **file-registry.md 已追加 §4**（TP4 新功能索引）——见文档引用审计报告。
2. /tmp 两个一次性脚本：建议移入 /opt/aicad-prod/scripts/tools/ 并补注释，或直接删除。
3. 部署指南 §5.1（8/13 补丁表）与附录（8/16 Stage B 链）建议加一行交叉引用，避免读者误以为 §5.1 是当前补丁链。
4. 新增脚本时把"注释头"纳入 check_vllm_script.sh 的校验项（可选增强）。

## 6. 归档状态补充（2026-08-17 晚，Rex 清理后）

- 本次补充过注释的 **v027-test（21 个）与 2hop-s1（26 个）脚本原目录已由 Rex 清理归档**：
  - 2hop-s1 → /opt/aicad-prod/backup/2hop-s1-archive-20260817.tar.gz（归档包含注释补充后的版本）
  - v027-test → 已移除（测试镜像另归档 backup/v027-nvfp4-archive-20260815/）
- 因此这些脚本的注释引用以归档内容为准；live 目录不再保留。
- 其余补充过的生产/基准脚本（start_tp4 变体、bench_v2.py、bench_prefill_decode_async.py 等）仍在原位置，注释引用生效。

---

*报告落盘：本地 deliverables/engineering-assurance/nccl-script-comment-audit-qa-2026-08-17.md + 服务器 /opt/aicad-prod/docs/*
