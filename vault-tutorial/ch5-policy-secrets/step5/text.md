# 第五步：删除策略并卸载机密引擎

先删除 `team-reader` 策略。该操作删除的是 Vault 服务器端策略对象，不会删除本地的 `/root/team-reader.hcl` 文件。

```bash
vault policy delete team-reader
vault policy list
```

使用刚才那枚受限 token 再次读取机密。由于它关联的策略已经被删除，访问应当失败。

```bash
VAULT_TOKEN=$TEAM_TOKEN vault kv get team-secrets/app/config 2>&1 | tail -5
```

接着禁用 `team-secrets/` 机密引擎。请注意，禁用挂载点是销毁性操作；在本实验的临时环境中可以执行，在生产环境中必须先评估撤销和数据影响。

```bash
vault secrets disable team-secrets/
```

确认挂载点已经消失，并尝试读取旧路径。

```bash
vault secrets list | grep -E 'Path|team-secrets/' || true
vault kv get team-secrets/app/config 2>&1 | tail -5
```

最后观察本地策略文件仍然存在。这有助于区分本地文件与 Vault 服务器端策略对象：删除服务器端策略不会自动删除你磁盘上的文件。

```bash
ls -l /root/team-reader.hcl
```

本步骤的重点是理解生命周期终点：`policy delete` 终止命名策略的授权效果，`secrets disable` 终止机密引擎挂载点本身。
