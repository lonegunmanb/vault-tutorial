# 第三步：increment 是「从现在开始算」——可以主动缩短租约

这一步演示文档 §4.1 那条最反直觉的论断：

> The requested increment is **not** an increment at the end of the current
> TTL; it is an increment from the current time.

也就是说，**应用可以通过续约让自己手里的凭据提前过期**。

签一份新凭据（前一份大概率已经被天花板撞死了）：

```bash
vault read database/creds/readonly
LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r ".[-1]")
FULL_LEASE_ID="database/creds/readonly/$LEASE_ID"
```

看一眼当前 TTL（默认 60 秒）：

```bash
vault lease lookup "$FULL_LEASE_ID" | grep -E "ttl|expire"
```

现在做一件"看起来在续约、实际在缩短"的事——申请 increment=10：

```bash
vault lease renew -increment=10 "$FULL_LEASE_ID"
```

返回的 `lease_duration` 是 **10**，不是 60。再确认一下：

```bash
vault lease lookup "$FULL_LEASE_ID" | grep -E "ttl|expire"
```

`expire_time` 已经被往**前**挪到了"现在 + 10s"。再过 10 秒：

```bash
sleep 12 && vault lease lookup "$FULL_LEASE_ID" 2>&1 || echo "(已过期)"
```

应该看到 `invalid lease`——这条凭据已经被 Vault 自动 revoke 了，对应的
Postgres 用户也消失了：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%';"
```

## 这个设计为什么有用？

回想一下应用的真实场景：

> 我的请求 handler 拿一份数据库凭据，**只会用 5 秒**——
> 不需要默认的 1 分钟 TTL，更不需要 5 分钟的 max_ttl。

按这个模型，应用应该：

1. `vault read database/creds/readonly` 拿凭据；
2. **立刻** `vault lease renew -increment=10`，把租约缩到 10 秒；
3. 用完就完，不需要主动 revoke——10 秒后 Vault 自己回收。

这样 Postgres 里同时存活的临时用户数量就被压到了**实际并发数 × 10 秒**，
而不是 **实际并发数 × default_ttl**。一个大流量服务靠这种"自缩短"
模式，能让目标系统侧的资源占用降一个数量级。

> 文档 §4.1 把这种用法描述为：
>
> > makes it easy for users to reduce the length of leases if they don't
> > actually need credentials for the full possible lease period, allowing
> > those credentials to expire sooner and resources to be cleaned up earlier.

`vault-basics` 第 4 步的 `vault lease renew "$FULL_LEASE_ID"` 命令没有
带 `-increment`，那种用法是"按服务端默认顶满"。带上 `-increment=N` 才
是真正用足这个 API 的能力。
