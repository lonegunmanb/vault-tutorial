# 第四步：Token revoke 的级联清理

文档 §5.2 的核心论断：

> When a token is revoked, Vault will revoke all leases that were created
> using that token.

这一步要的画面感是：**一句 `vault token revoke`，让 Postgres 里一批账号
集体消失**。

先签一个挂着 `app` 策略的 Token，模拟一个应用：

```bash
APP_TOKEN=$(vault token create -policy=app -ttl=24h -format=json | jq -r .auth.client_token)
echo "$APP_TOKEN"
```

切换成 app 身份，让它去签 3 份动态凭据（这 3 份租约的"父 Token"就是它）：

```bash
export ADMIN_TOKEN=root
export VAULT_TOKEN=$APP_TOKEN

vault read database/creds/readonly
vault read database/creds/readonly
vault read database/creds/readonly
```

切回管理员，看一下 Postgres 里现在有几个 `v-` 用户：

```bash
export VAULT_TOKEN=$ADMIN_TOKEN
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%';"
```

应该看到 3 个新用户。再列一下租约：

```bash
vault list sys/leases/lookup/database/creds/readonly
```

现在按"应用下线"的剧本——撤掉 `$APP_TOKEN`：

```bash
vault token revoke "$APP_TOKEN"
```

**立刻**回 Postgres 看：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%';"
```

那 3 个用户**全部消失了**。Vault 在执行 token revoke 时，按内部"父 Token →
子租约"的索引把这个 Token 创建的所有租约找出来，**对每一条都调一次
对应引擎的 Revoke 钩子**——也就是 database 引擎依次去 Postgres 里
`DROP ROLE`。

再确认一下租约表也清空了：

```bash
vault list sys/leases/lookup/database/creds/readonly 2>&1 || echo "(没有租约了)"
```

## 业务含义

这是 Vault 提供的一个非常重的安全保证：

- 一个**应用**下线 → revoke 这个应用的 Token → 它在数据库 / AWS / GCP /
  K8s 等所有目标系统侧的临时凭据**自动清理**；
- 一个**员工**离职 → revoke 这个员工的 Token → 他生前签出去的所有动态
  凭据**自动失效**。

传统密码管理工具里，要做到这个效果你得维护一张"谁拿了哪些密码"的台账，
还得登录每个目标系统挨个删。Vault 把"父 Token → 子租约"这条索引
**做进了内核**，于是一句话就能完成。

> 注意：被 revoke 的 Token 自己也立刻失效，再用它去 read 任何东西都
> 会返回 403。这同样是安全保证的一部分——下线的 Token 不能复活。
