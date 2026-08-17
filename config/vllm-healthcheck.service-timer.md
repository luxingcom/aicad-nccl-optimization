# vllm-healthcheck.service / timer（自恢复探针，P1 2026-08-17 启用）

## 设计
- 探针失败 → `docker rm -f` 本机 vllm 容器 → monitor 的 `docker wait` 返回 → systemd 重启 → 重建
- 冷却窗口 1800s 防风暴（原 600s → 1800s）
- 修正点：原触发方式 `systemctl restart $SVC` 对"容器在但 API 挂"场景无效（monitor docker wait 阻塞）
  → 改为 `docker rm -f $(docker ps -aq --filter name=vllm-tp4-rank)`
- timer 修正点：原方案仅 `OnUnitActiveSec=60s` 不触发（服务无历史激活参考点）
  → 标准组合 `OnActiveSec=60s`（timer 激活后 60s 首触发）+ `OnUnitActiveSec=60s`（运行后 60s 重复）

## vllm-healthcheck.service（oneshot）
```
[Unit]
Description=vLLM TP4 healthcheck-rebuild (oneshot)
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/aicad-prod/scripts/healthcheck-rebuild.sh --role head --cooldown 1800
```

## vllm-healthcheck.timer（60s 周期）
```
[Unit]
Description=Run vLLM TP4 healthcheck every 60s

[Timer]
OnActiveSec=60s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
```
