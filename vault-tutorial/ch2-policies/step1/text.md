# 第一步：最小 policy + capabilities 与 `-output-policy`

文档 §1 那两句要先记住：

> Everything in Vault is path-based. Policies are deny by default.

我们先用 dev 模式默认挂的 KV v2（在 `secret/` 路径）来体会"默认拒绝"
和"刚好够用的 capabilities"。

## 1.1 写一条最小 policy

```bash
vault kv put secret/hello message="hi from vault"
```

写一条 policy 只允许读 `secret/hello`：

```bash
vault policy write read-hello - <<'EOF'
path "secret/data/hello" {
  capabilities = ["read"]
}
EOF
```

> 注意——KV v2 的实际数据路径是 `secret/data/hello`，不是
> `secret/hello`。`vault kv get secret/hello` 这种 CLI 简写底下走的
> HTTP 是 `GET /v1/secret/data/hello`，policy 必须按真实 API 路径写。

## 1.2 拿一个挂这条 policy 的 token，验证"刚好够用"

```bash
TOKEN=$(vault token create -policy=read-hello -format=json | jq -r .auth.client_token)

# 先用 root 写一条 secret/world，给后面的"读失败"做准备（输出抑制掉避免混淆）
vault kv put secret/world message="other" > /dev/null

echo "读 secret/hello（应该成功）:"
VAULT_TOKEN=$TOKEN vault kv get secret/hello | grep message

echo ""
echo "读 secret/world（应该失败 - 不在 policy 里）:"
VAULT_TOKEN=$TOKEN vault kv get secret/world 2>&1 | tail -3

echo ""
echo "写 secret/hello（应该失败 - 没有 update capability）:"
VAULT_TOKEN=$TOKEN vault kv put secret/hello message="changed" 2>&1 | tail -3

echo ""
echo "用 vault token capabilities 直接看 TOKEN 在 secret/data/hello 上的能力:"
vault token capabilities $TOKEN secret/data/hello
# 输出只有 "read"——所以 PUT/POST 必然 403，因为缺 update / create
```

三个反应分别是：成功 / 403 未授权 / 403 capability 不足。Vault 自身
返回的 403 信息只有一句 `permission denied`，**不会告诉你具体差哪个
capability**——所以排查时第一手段就是上面这条
`vault token capabilities <token> <path>`，**它会列出该 token 在该路
径上实际拥有的能力集合**，对照需求就能看出少了哪一个。这正是"deny by
default + capabilities 精确控制"的体现。

## 1.3 不知道某个命令需要什么 capability？用 `-output-policy`

文档 §1.2 说的偷懒招——任何命令前面加 `-output-policy` 就能反推 policy：

```bash
echo "vault kv get 需要什么权限:"
vault kv get -output-policy secret/hello

echo ""
echo "vault kv put 需要什么权限:"
vault kv put -output-policy secret/hello message=test
```

注意 `kv put` 的输出里 capabilities 是 `["create", "update"]` 两个
都要——这就是文档强调的"绝大多数 Vault 路径不区分 create 和 update，
**默认就要一起写**"。

## 1.4 体验 `read` capability 其实可能在"创建新账号"

最容易让人困惑的是 `database` 引擎的动态机密接口——业务上它**每被调
一次就在目标数据库里创建一个新用户**（参考基础篇第 4 步），但底层
HTTP 动词是 GET，所以 ACL 上**只需要 `read`**。

后台脚本已经为你启动了一个 Postgres 容器（`learn-postgres`，超级用户
`root` / `rootpassword`，监听 `5432`，里面预先建好了一个 `ro` 只读
角色）。

启用 database 引擎并把 Postgres root 凭据交给 Vault：

```bash
vault secrets enable database

vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@localhost:5432/postgres?sslmode=disable" \
  allowed_roles=readonly \
  username="root" \
  password="rootpassword"
```

写一个 Vault 创建临时数据库用户的 SQL 模板，并注册成 `readonly` 角色
（TTL 1 分钟，方便观察）：

```bash
tee /root/readonly.sql > /dev/null <<'EOF'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";
EOF

vault write database/roles/readonly \
  db_name=postgresql \
  creation_statements=@/root/readonly.sql \
  default_ttl=1m \
  max_ttl=24h
```

先用 `-output-policy` 看签发动态凭据需要的能力：

```bash
echo "vault read database/creds/readonly 需要什么权限:"
vault read -output-policy database/creds/readonly
```

输出会是：

```hcl
path "database/creds/readonly" {
  capabilities = ["read"]
}
```

注意——**只要 `read`，没有 `create` 也没有 `update`**。按这条 policy
签一个最小权限 token，让它去申请一份动态凭据：

```bash
vault policy write app-db - <<'EOF'
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF

APP=$(vault token create -policy=app-db -format=json | jq -r .auth.client_token)

echo "用只有 read 的 token 调用 database/creds/readonly:"
VAULT_TOKEN=$APP vault read database/creds/readonly
```

输出里会出现一组 `username = v-token-readonly-xxxxx` / 随机 `password`
/ `lease_duration = 60s`——**这一次 GET 请求在 Postgres 里实实在在
创建了一个新用户**。

直接进 Postgres 验证：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token%';"
```

你会看到刚刚那个 `v-token-readonly-...` 用户**真实存在**于 `pg_user`
里，过期时间是 60 秒之后。

**仔细体会这个反差**：

- 业务语义：调用一次就在 PostgreSQL 里**新建一个临时用户**，返回随机
  用户名密码，挂一个 lease；
- HTTP 语义：`GET /v1/database/creds/readonly`；
- ACL 语义：**`read`**（不是 `create` / `update`）。

**写 policy 永远以 HTTP 动词为准，不要被"它实际在干什么"误导**。同样
反直觉的还有 `pki/issue/<role>`——名字带 issue，但底层是 POST，所以
需要 `update` / `create`，而不是 `read`。判断一个 Vault API 真正的
HTTP 动词最简单的办法就是 `-output-policy` 反推一次，让 CLI 帮你回答。

**这一步的核心结论**：

| 现象 | 原因 |
| --- | --- |
| 路径不在 policy 里 → 403 | deny by default |
| 路径在 policy 里但 capability 不全 → 403 | capabilities 也是 deny by default |
| `kv put` 同时需要 `create` + `update` | 多数 Vault API 不区分这两者 |
| `kv get` 需要 `read`（哪怕底层是"生成新凭据"） | policy 跟 HTTP 动词对齐，不是业务语义 |
| 不知道写什么 capability | `-output-policy` 自动反推 |
