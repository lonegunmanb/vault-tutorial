# 第二步：max_lease_ttl 是续约的硬天花板

文档 §3.2 的核心论断：

> 任何一份机密，从签发那一刻起，最多只能活 `max_ttl`，
> **无论续约多少次**。

我们的 `readonly` 角色配置：`default_ttl=1m`，`max_ttl=5m`。
这一步要把这条天花板撞出来。

继续用第 1 步留下的 `$FULL_LEASE_ID`（如果新开的终端，重新算一遍）：

```bash
LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r ".[0]")
FULL_LEASE_ID="database/creds/readonly/$LEASE_ID"
echo "$FULL_LEASE_ID"
```

申请一个**远超 max_ttl 的 increment**——比如 1 小时：

```bash
vault lease renew -increment=3600 "$FULL_LEASE_ID"
```

注意输出里的 `lease_duration` 字段：**它绝对不会是 3600，最多是 300（5 分钟）**，
而且实际上会更小——具体值 = `issue_time + max_ttl - now`，也就是
"距离这条租约的死刑日还剩多久"。

这正是文档 §4.2 强调的：

> The requested increment is completely advisory.

再连续续两次：

```bash
sleep 5 && vault lease renew -increment=3600 "$FULL_LEASE_ID"
sleep 5 && vault lease renew -increment=3600 "$FULL_LEASE_ID"
```

每次都申请 1 小时，每次返回的 `lease_duration` 都在**单调递减**。这就是
天花板效应——再怎么续，也越不过最初签发时锁定的 5 分钟死刑日。

为了直观看到死刑日，看一下完整的 lookup：

```bash
vault lease lookup "$FULL_LEASE_ID"
```

注意：

- `issue_time` 是固定的（第 1 步签出来时刻）
- `expire_time` 永远 ≤ `issue_time + 5m`
- `last_renewal` 这次开始有值了

等到这条租约过了 5 分钟自然死亡（或者直接进入第 3 步，反正它会自己消失），
你就会看到对应的 Postgres 用户被 Vault 删掉。

> **生产含义**：如果你的应用号称"我会一直续约所以可以拿一份永久凭据"——
> 不可能。`max_lease_ttl` 是底线安全保障，强迫每一份机密都有一个**确定的
> 失效时刻**。这样泄露后的爆炸半径就能被精确量化为「最多 max_ttl」。
