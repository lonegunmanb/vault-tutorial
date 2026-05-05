# 第二步：管理单条动态机密 lease

本步骤会从 `database/creds/readonly` 读取一组动态 PostgreSQL 凭据，并对它的 lease 执行查询、续期和撤销。

先读取动态凭据，并保存完整 JSON 响应：

```bash
CREDS_JSON=$(vault read -format=json database/creds/readonly)
echo "$CREDS_JSON" | jq '{lease_id, lease_duration, renewable: .renewable, username: .data.username}'
```

提取 lease ID：

```bash
LEASE_ID=$(jq -r .lease_id <<< "$CREDS_JSON")
echo "$LEASE_ID"
```

查询租约详情：

```bash
vault lease lookup "$LEASE_ID"
```

重点观察以下字段：

- `ttl`：当前剩余有效时间
- `renewable`：这条租约是否允许续期
- `issue_time` 与 `expire_time`：签发时间与到期时间

请求把租约续期到 5 分钟。这里的 `300` 表示秒；Vault 会根据角色的最大 TTL 等限制决定最终返回值。

```bash
vault lease renew -increment=300 "$LEASE_ID"
vault lease lookup "$LEASE_ID"
```

最后主动撤销这条租约：

```bash
vault lease revoke "$LEASE_ID"
```

撤销后再次查询应失败：

```bash
vault lease lookup "$LEASE_ID" 2>&1 | tail -3
```

这一阶段的关键点是：`lease renew` 延长的是凭据的有效时间，不会改变动态数据库用户名和密码本身；`lease revoke` 则会使底层动态凭据失效。