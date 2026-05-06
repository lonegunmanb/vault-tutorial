# 第五步：运行 diagnose、usage 并阅读 migrate 配置

先对第一步的文件存储 Vault 配置运行诊断。因为它现在已经启动并运行，某些检查可能出现 warning；本步骤的目标是识别输出结构，而不是追求零 warning。

```bash
vault operator diagnose -config=/root/operator-lab/single.hcl | head -120
```

把输出换成 JSON，便于脚本处理：

```bash
vault operator diagnose \
  -format=json \
  -config=/root/operator-lab/single.hcl | jq 'keys'
```

运行 usage 报告。实验环境中通常不会有足够的 client count 历史数据，因此可能返回无数据或很小的结果；重点观察列名和时间范围。

```bash
export VAULT_ADDR='http://127.0.0.1:8400'
export VAULT_TOKEN="$(jq -r '.root_token' /root/operator-lab/raft-init.json)"

vault operator usage || true
vault operator usage -start-time=2026-01 -end-time=2026-01 || true
```

最后阅读离线存储迁移配置。这里不直接执行迁移，因为 `operator migrate` 要求 Vault 停机，并且目标 storage 不应初始化；本实验只让你识别配置形态和操作边界。

```bash
cat /root/operator-lab/migrate-file-to-raft.hcl
```

配置中的 `storage_source` 指向第一步文件存储 Vault 的数据目录，`storage_destination` 指向一个新的 Raft 数据目录。真实执行时，应先停止源 Vault，再运行类似命令：

```bash
# 示例：不要在本步骤直接运行
vault operator migrate -config=/root/operator-lab/migrate-file-to-raft.hcl
```

观察要点：`diagnose` 是故障排查仪表盘；`usage` 是客户端用量报告；`migrate` 是离线存储层复制，不是在线挂载路径迁移。