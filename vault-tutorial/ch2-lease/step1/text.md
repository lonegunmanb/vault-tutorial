# 第一步：lease_id 的前缀结构与 sys/leases 的层级

理论文档 §3.1 说过：**lease_id 的开头永远是当初读这个秘密时用的 API
路径**。这一步我们用眼睛验证它，并顺便看清 `sys/leases/lookup/...`
是怎么按路径组织成一棵树的。

签出第一份动态凭据：

```bash
vault read database/creds/readonly
```

注意输出第一行的 `lease_id`，形如：

```
lease_id    database/creds/readonly/abcDEF123...
```

前缀 `database/creds/readonly/` 不是巧合——这就是你 read 时用的 URL 路径。
后面那串随机字符才是这一**次签发**的唯一 ID。

再签两份，凑够三份：

```bash
vault read database/creds/readonly
vault read database/creds/readonly
```

现在到 Postgres 看看，确认 Vault 帮你创建了三个临时用户：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%';"
```

接下来用 `sys/leases/lookup` 列出所有租约——注意它必须用 `list` 而不是 `read`：

```bash
vault list sys/leases/lookup/database/creds/readonly
```

你会看到三个后缀 ID。再往上一层看：

```bash
vault list sys/leases/lookup/database/creds/
vault list sys/leases/lookup/database/
```

`sys/leases/lookup/` 这棵树严格按你**挂载点 + 路径 + 角色名**来分叉——
正是这个层级结构，让我们能在第 5 步用 `-prefix` 砍掉某一类租约。

最后看一条具体租约的元数据：

```bash
LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r ".[0]")
FULL_LEASE_ID="database/creds/readonly/$LEASE_ID"
vault lease lookup "$FULL_LEASE_ID"
```

输出里几个关键字段对应文档 §3：

- `issue_time` / `expire_time` / `ttl` —— §3 的租约骨架
- `renewable true` —— 决定下一步能不能 renew
- `last_renewal` —— 暂时是 `n/a`，下一步操作完后会被填上

把 `$FULL_LEASE_ID` 留着，第 2 步要用。
