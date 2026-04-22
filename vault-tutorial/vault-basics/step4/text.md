# 第四步：动态机密（Dynamic Secrets）

前面三步学的都是 KV 引擎——**人写进去、人读出来**的静态机密。Vault 真正
颠覆传统密码管理方式的能力在于 **Dynamic Secrets**：机密在被请求的那一刻才
由 Vault 现场生成，每次返回的用户名密码都不一样，并且带一个有限的租约（Lease），
租约到期或被吊销时，Vault 会自动登录到目标系统把这个账号删掉。

本节我们用 Postgres + Vault 的 `database` Secrets Engine 演示这个流程。

> 后台脚本已经为你启动了一个 Postgres 容器（`learn-postgres`，超级用户
> `root` / `rootpassword`，监听 `5432`），并预先创建了一个名为 `ro` 的只读
> 角色——后续 Vault 动态生成的临时用户都会继承这个角色的权限。

---

## 1. 角色分工

参考 [vault.md](https://github.com/lonegunmanb/hashistack_session/blob/main/vault/vault.md) 的设计，本实验中有两个角色：

| 角色 | 身份 |
| --- | --- |
| `admin` | Vault 与 Postgres 的管理员，配置数据库引擎、定义角色与策略 |
| `app`   | 应用程序，只能调用 `database/creds/readonly` 取动态凭据 |

我们会先用 root token 扮演 `admin` 完成所有配置，再签发一个只能 `read`
凭据的 token 扮演 `app`。

---

## 2. 启用并配置 database Secrets Engine（admin）

确认环境变量已就绪：

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
```

启用 database 引擎：

```bash
vault secrets enable database
```

把 Postgres 的 root 凭据交给 Vault，让它有能力**代我们去 Postgres 里建删用户**：

```bash
vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@localhost:5432/postgres?sslmode=disable" \
  allowed_roles=readonly \
  username="root" \
  password="rootpassword"
```

> `?sslmode=disable` 仅为本实验方便，**生产环境一定要启用 TLS**。
>
> `{{username}}` / `{{password}}` 是 Vault 在向 Postgres 发起连接时会自动
> 替换的占位符，让这条连接串既能用初始 root 凭据，也能在后续轮转 root
> 密码时无缝接管。

---

## 3. 定义动态用户的生成模板（admin）

Vault 需要知道**怎么在 Postgres 里创建用户**。把 SQL 模板写到一个文件里：

```bash
tee /root/readonly.sql <<'EOF'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";
EOF
```

`{{name}}`、`{{password}}`、`{{expiration}}` 是 Vault 在每次签发凭据时
现场填入的——这意味着每个临时用户的名字、密码、过期时间都不一样。

把模板注册成一个名为 `readonly` 的角色，默认 TTL = 1 分钟，最大 24 小时：

```bash
vault write database/roles/readonly \
  db_name=postgresql \
  creation_statements=@/root/readonly.sql \
  default_ttl=1m \
  max_ttl=24h
```

> 把 TTL 故意设成 1 分钟是为了让你能**亲眼看到租约到期后用户消失**。
> 生产环境通常会设成几小时到 24 小时。

---

## 4. 给 `app` 颁发最小权限 token（admin）

写一条只能读 `database/creds/readonly` 的策略：

```bash
vault policy write app -<<EOF
path "database/creds/readonly" {
  capabilities = [ "read" ]
}
EOF
```

签发一个挂着 `app` 策略的 token，并把它保存下来：

```bash
APP_TOKEN=$(vault token create -policy=app -format=json | jq -r .auth.client_token)
echo "$APP_TOKEN"
```

---

## 5. 应用以 `app` 身份取动态凭据

切换成 `app` 身份（保留 admin 的 root token 在另一变量里以便后续操作）：

```bash
export ADMIN_TOKEN=root
export VAULT_TOKEN=$APP_TOKEN
```

**第一次**请求凭据：

```bash
vault read database/creds/readonly
```

输出会包含一个 `lease_id`、`username`（形如 `v-token-readonly-xxxx`）、
`password`，以及 `lease_duration 60s`。

**再请求一次**——你会看到完全不同的用户名密码：

```bash
vault read database/creds/readonly
```

到 Postgres 验证这两个临时用户**真的存在**：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user;"
```

你会看到 `root` 之外多出两个 `v-token-readonly-...` 用户，其
`valuntil` 各自比当前时间多 60 秒。

---

## 6. 管理租约（admin）

切回管理员身份：

```bash
export VAULT_TOKEN=$ADMIN_TOKEN
```

列出所有 `readonly` 角色当前在跑的租约：

```bash
vault list sys/leases/lookup/database/creds/readonly
```

把第一个租约 ID 抓出来：

```bash
LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r ".[0]")
FULL_LEASE_ID="database/creds/readonly/$LEASE_ID"
echo "$FULL_LEASE_ID"
```

查看这条租约的剩余时间：

```bash
vault lease lookup "$FULL_LEASE_ID"
```

**续约**——把 TTL 重新顶满到 default_ttl：

```bash
vault lease renew "$FULL_LEASE_ID"
```

**主动吊销**——立刻让这个数据库账号失效：

```bash
vault lease revoke "$FULL_LEASE_ID"
```

回到 Postgres 确认 Vault **真的去把那个用户删掉了**：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user;"
```

刚才被 revoke 的那个 `v-token-readonly-...` 已经从 `pg_user` 里消失。

---

## 7. 见证「租约到期 = 账号自动消失」

剩下那个用户的 TTL 只有 1 分钟。等大约 60–90 秒后再查：

```bash
sleep 75 && docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user;"
```

它也被 Vault 后台的 lease expiration 进程清掉了——**没有人去手动删，
应用程序也没有任何「我用完了」的通知**，整个生命周期完全由 Vault 接管。

---

## 这一步的意义

把这一节学到的东西和前 3 节对比一下：

| 维度 | KV（前 3 节） | Dynamic Secrets（本节） |
| --- | --- | --- |
| 谁创建机密 | 人 | Vault 现场生成 |
| 同一密钥两次读到的值 | 相同 | **不同** |
| 失效方式 | 显式 delete/destroy | TTL 自动到期或 lease revoke |
| 凭据泄漏后的爆炸半径 | 直到下次轮换 | 最多到 max_ttl，且可一键 revoke |
| 应用故障时回滚 | 改配置 + 重启 | 撤销租约即可，目标系统侧自动清理 |

这就是 Vault 文档里反复强调的 **secret zero** 缩减——应用拿到的不再是
一份长期有效、人人都能看的「主密码」，而是一段**用过即焚**的临时凭据。
