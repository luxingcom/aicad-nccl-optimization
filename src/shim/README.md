# src/shim/ — libncclpin（线程绑核 shim）

## 概述

`libncclpin.so` 是生产 **LD_PRELOAD 链的一部分**（与定制 `libnccl.so.2` 一起预加载），负责将 NCCL 数据面线程绑定到隔离核（isolcpus=8-9），降低与 vLLM EngineCore 的调度争用。

生产加载链（start_tp4_head.sh / start_tp4_worker.sh）：
```
LD_PRELOAD=/opt/aicad-prod/lib/libncclpin.so /opt/nccl-ringonly/libnccl.so.2
```

## 版本关系（重要）

| 版本 | 状态 | md5 | 源码 |
|---|---|---|---|
| **v8（生产实际加载）** | ✅ 生产中（libncclpin.so，ce43c688） | ce43c688c516... | ⚠️ **源码缺失**（未归档，仅二进制；strings 证实为 ncclpin_v8.c） |
| **v9（本目录源码）** | 📦 归档（backup/ncclpin-v9/，2026-08-14） | 69f20139c993... | ✅ ncclpin_v9.c（本文件） |

**v9 相对 v8 的变更**（源码头注释）：
1. NCCL 数据面线程 → CPU 8-9（隔离核；旧 v3 写 0-4 依据过时文档已修正）
2. 其他线程 → CPU 5-19（与生产 v8 一致，零回归）
3. `thread_entry` 竞态修复：per-create malloc + 原子 consumed + 入口内 free
4. 环境开关：`NCCLPIN_VERBOSE=1` 控制日志、`NCCLPIN_DISABLE=1` 完全禁用
5. 线程名匹配表：`NCCL* / pt_nccl* / pt_tcpstore* / *Proxy*` → CPU 8-9；其他 → CPU 5-19

> **说明**：生产当前加载 v8（ce43c688）。v9 是修复版（isolcpus 布局修正 + 竞态修复），尚未替换上线。v8 源码未归档——如需重建 v8 精确副本需从二进制反推（不建议），建议升级验证 v9 后作为生产基线。

## 编译参考

```bash
gcc -O2 -shared -fPIC -o libncclpin.so ncclpin_v9.c -lpthread -ldl
# 产物放置：/opt/aicad-prod/lib/libncclpin.so（或按部署指南）
```

## 关联

- 部署指南 §5.1（LD_PRELOAD 链）
- 运维手册 §2/§4（启动与工具）
- 绑核设计依据：CPU 拓扑实测（isolcpus=8-9 为 X925 3900MHz 隔离核）
