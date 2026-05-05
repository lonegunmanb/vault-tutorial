# 第二步：调优、迁移与禁用机密引擎

先读取 `team-kv/` 的挂载点调优配置。`sys/mounts/<path>/tune` 是观察挂载点参数的常用系统路径。

```bash
vault read sys/mounts/team-kv/tune | grep -E 'default_lease_ttl|max_lease_ttl|description'
```

使用 `vault secrets tune` 调整挂载点描述和 TTL。虽然 KV 保存的是静态数据，本步骤仍然可以用它观察挂载点配置如何被修改。

```bash
vault secrets tune \
  -description="Team secret storage for CLI lab" \
  -default-lease-ttl=30m \
  -max-lease-ttl=2h \
  team-kv/
```

再次读取 tune 配置，确认描述和 TTL 已经变化。

```bash
vault read sys/mounts/team-kv/tune | grep -E 'default_lease_ttl|max_lease_ttl|description'
```

接着把 `team-kv/` 迁移到 `team-secrets/`。`vault secrets move` 会输出迁移开始和完成的信息；对本实验的小数据集而言，迁移几乎会立即结束。

```bash
vault secrets move team-kv/ team-secrets/
```

验证旧路径已经不再作为挂载点出现，新路径已经可用，并读取刚才写入的数据。

```bash
vault secrets list | grep -E 'Path|team-'
vault kv get team-secrets/app/config
```

最后创建一个临时挂载点，并立即禁用它，用来观察 `disable` 的语义。禁用机密引擎会卸载该路径，因此后续从该路径读取会失败。

```bash
vault secrets enable -path=scratch-kv -description="Temporary scratch mount" -version=2 kv
vault kv put scratch-kv/example note="temporary"
vault secrets disable scratch-kv/
vault kv get scratch-kv/example 2>&1 | tail -4
```

本步骤的重点是区分三个动作：`tune` 修改挂载配置，`move` 改变挂载路径，`disable` 卸载挂载点并结束该引擎的生命周期。
