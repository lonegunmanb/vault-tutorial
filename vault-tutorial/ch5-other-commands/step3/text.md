# 第三步：按前缀批量撤销 lease

单条 lease 适合精确回收一个凭据；前缀撤销适合回收同一类路径下的多条租约。本步骤会生成两条动态数据库凭据，然后按 `database/creds/readonly` 前缀统一撤销。

先生成两条新的动态凭据：

```bash
vault read database/creds/readonly
vault read database/creds/readonly
```

列出当前 `readonly` 角色下的租约后缀：

```bash
vault list sys/leases/lookup/database/creds/readonly
```

如果希望看到完整 lease ID，可以把前缀补回去：

```bash
vault list -format=json sys/leases/lookup/database/creds/readonly \
  | jq -r '.[] | "database/creds/readonly/" + .'
```

现在同步撤销这个前缀下的所有租约：

```bash
vault lease revoke -prefix -sync database/creds/readonly
```

再次列出同一路径，通常应看不到可用租约：

```bash
vault list sys/leases/lookup/database/creds/readonly 2>&1 | tail -5
```

这一阶段的关键点是：`-prefix` 会扩大撤销范围，`-sync` 会等待撤销动作完成。生产环境中应尽量使用足够具体的前缀，避免误伤同一后端下其他业务凭据。