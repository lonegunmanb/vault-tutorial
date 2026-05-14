# 第一步：AWS IAM (LocalStack) → Vault → PostgreSQL 动态凭据

把 [9.6 章正文](https://lonegunmanb.github.io/vault-tutorial/ch9-identity-broker-postgres.html)
讲过的"AWS to PostgreSQL"完整流水线在终端里跑一遍：用 LocalStack 模拟
AWS 的 IAM/STS 服务，让一名"业务主机身份"用 IAM 凭据登录 Vault，再请
Vault 现场签发一份**短生命周期**的 PostgreSQL 临时账号，用临时账号
直连数据库执行业务 SQL，最后 revoke lease 验证账号被 Vault 主动 DROP。

> 端到端流水线：AWS access key → `vault login -method=aws` → Vault token
> → `vault read database/creds/readonly` → `username/password` → `psql`
> → `vault lease revoke` → 临时账号在 PG 上消失。

## 1.1 在 LocalStack 上创建一个 IAM user 作为"业务主机身份"

LocalStack 的 root 凭据 `test/test` 是 account `000000000000` 上的
**root**——Vault 的 iam auth 路径**不能**把 root ARN 当普通可登录身份
解析（参考 [4.3 章实验](https://lonegunmanb.github.io/vault-tutorial/ch4-aws.html)
Step 2.1）。所以先建一个真正的 IAM user 并抓出它的 access key：

```bash
awslocal iam create-user --user-name app-aws
APP_KEY_JSON=$(awslocal iam create-access-key --user-name app-aws)
APP_AK=$(echo "$APP_KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
APP_SK=$(echo "$APP_KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
echo "APP_AK=$APP_AK"
echo "APP_SK=$APP_SK"
```

确认这对凭据签出来的身份 ARN 是 `user/app-aws`：

```bash
AWS_ACCESS_KEY_ID=$APP_AK AWS_SECRET_ACCESS_KEY=$APP_SK \
    awslocal sts get-caller-identity
```

应输出：

```json
{
    "UserId": "...",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:user/app-aws"
}
```

> 这是 brokering 的 **Phase 1 输入**——调用方在外部身份域里"到底是谁"
> 已经被 IdP（这里是 LocalStack STS）确认。下面让 Vault 与 LocalStack
> 对上 STS 端点。

## 1.2 启用并配置 Vault aws auth method

```bash
vault auth enable aws

vault write auth/aws/config/client \
    access_key=test \
    secret_key=test \
    endpoint=http://127.0.0.1:4566 \
    iam_endpoint=http://127.0.0.1:4566 \
    sts_endpoint=http://127.0.0.1:4566 \
    sts_region=us-east-1 \
    iam_server_id_header_value=vault.example.com
```

> `access_key`/`secret_key` 是 **Vault 自己**调 AWS API 用的（不是登录方
> 的）；`sts_endpoint` 是 Vault 转发 `GetCallerIdentity` 验签时打的端点，
> **必须**与登录方 CLI 端的端点一致。`iam_server_id_header_value` 是
> [4.3 章 §2](/ch4-aws) 那道防重放 header 的服务端值。

## 1.3 创建 brokering 的 Phase 2 入口：Vault aws role + ACL policy

先写一条 ACL policy，**只允许**访问 `database/creds/readonly` 这一条
路径。这就是 Phase 2 的全部——纯 Vault 内部、deny-by-default、HCL 写：

```bash
cat > /root/db-readonly.hcl <<'EOF'
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF

vault policy write db-readonly /root/db-readonly.hcl
vault policy read db-readonly
```

再创建一条 aws role，把它**精确绑定**到 1.1 那个 IAM user 的 ARN，并把
`db-readonly` policy 挂到 token 上：

```bash
vault write auth/aws/role/app-aws \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:user/app-aws \
    resolve_aws_unique_ids=false \
    policies=db-readonly \
    token_ttl=10m \
    token_max_ttl=30m

vault read auth/aws/role/app-aws
```

> `resolve_aws_unique_ids=false` 是**实验环境专用**的简化（生产建议留
> true，参考 [4.3 章实验](https://lonegunmanb.github.io/vault-tutorial/ch4-aws.html)
> Step 2.2 的注释）；`token_policies` 严格只挂 `db-readonly`，**不挂
> default**——Phase 2 就是这条 policy 列表说了算。

## 1.4 启用 database 引擎、配置 PostgreSQL 连接、立刻 rotate-root

```bash
vault secrets enable database

vault write database/config/postgres-broker \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="readonly" \
  connection_url="postgresql://{{username}}:{{password}}@127.0.0.1:5432/postgres?sslmode=disable" \
  username="vaultadmin" \
  password="vaultadmin" \
  password_authentication="scram-sha-256"

vault write -force database/rotate-root/postgres-broker
```

> `rotate-root` 后 `vaultadmin` 的旧密码立即失效——**只有 Vault 知道
> 新密码**。这一步在 brokering 范式里至关重要：Vault 是 PG 上"唯一持
> 有 admin 凭据的身份"，业务侧绝不可能拿到长期有效的 PG 账号。

## 1.5 创建 Phase 3 模板：database/roles/readonly

```bash
vault write database/roles/readonly \
  db_name="postgres-broker" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
                       GRANT USAGE ON SCHEMA demo TO \"{{name}}\";
                       GRANT SELECT ON ALL TABLES IN SCHEMA demo TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL ON ALL TABLES IN SCHEMA demo FROM \"{{name}}\";
                         REVOKE USAGE ON SCHEMA demo FROM \"{{name}}\";
                         DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="2m" \
  max_ttl="10m"

vault read database/roles/readonly
```

> 这条模板就是本节正文 Phase 3 的全部"权限边界"——`GRANT SELECT ON
> demo.*`、`DROP ROLE` 兜底——**完全在 PG 端定义**，Vault ACL 一个字
> 都不参与。第二步会**原封不动**地复用这条 role。

## 1.6 真实跑通 Phase 1：用 IAM user 凭据登录 Vault

实验环境默认 `export VAULT_TOKEN=root`，先 unset，避免 `vault login`
之后被旧的 root token 覆盖：

```bash
unset VAULT_TOKEN

AWS_ACCESS_KEY_ID=$APP_AK AWS_SECRET_ACCESS_KEY=$APP_SK \
    vault login -method=aws \
        role=app-aws \
        header_value=vault.example.com \
        sts_endpoint=http://127.0.0.1:4566 \
        sts_region=us-east-1
```

应输出 `Success! ...`，并在 metadata 里看到：

```text
token_meta_account_id    000000000000
token_meta_auth_type     iam
token_policies           ["db-readonly"]
```

> Vault 已经把 CLI 提交的 `GetCallerIdentity` 签名转给 LocalStack STS
> 验签，确认返回身份命中了 role 的 `bound_iam_principal_arn`，并签出
> 了一枚只挂 `db-readonly` 的 Vault token。Phase 1 完成。

## 1.7 把 Phase 2 + Phase 3 一气跑通：申领 PG 临时账号

```bash
CRED=$(vault read -format=json database/creds/readonly)
echo "$CRED" | jq

PG_USER=$(echo "$CRED" | jq -r .data.username)
PG_PASS=$(echo "$CRED" | jq -r .data.password)
LEASE_ID=$(echo "$CRED" | jq -r .lease_id)

echo "临时账号: $PG_USER"
echo "Lease ID: $LEASE_ID"
```

`PG_USER` 形如 `v-iam-readonly-xxxxxxxx-...`——前缀里的 `iam` 正是上游
auth method 名，这是 Vault 自动写入的审计信息，便于反向追溯凭据是从
哪条认证路径派生出来的。

旁路确认 PG 端真的多了这个账号：

```bash
PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='$PG_USER';"
# 应输出 $PG_USER
```

## 1.8 用临时账号实连 PostgreSQL 跑业务 SQL

```bash
PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -U "$PG_USER" -d postgres \
  -c "SELECT k, v FROM demo.kv ORDER BY k;"
```

应输出 `demo.kv` 的两行业务数据——这一刻就是本节正文 Phase 3 的"业务
凭据真的在目标域生效"的实测证据。

## 1.9 Revoke lease，验证 Vault 主动 DROP 临时账号

```bash
vault lease revoke "$LEASE_ID"
sleep 2

PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname='$PG_USER';"
# 应输出 0

PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -U "$PG_USER" -d postgres \
  -c "SELECT 1;" 2>&1 | head -2
# 应输出 FATAL: role "..." does not exist 或 password authentication failed
```

> 这就是本节正文 §2.3 末尾的核心特征——Vault 在 lease 到期或被显式
> revoke 时**主动**回到目标域执行 `revocation_statements`。临时账号的
> 整个生命周期都被 Vault 接管。

## 1.10 把 token 切回 root 给第二步用

```bash
export VAULT_TOKEN=root
vault token lookup | head -3
```

`policies` 应回到 `[root]`。

---

## ✅ 验收

- [ ] `vault login -method=aws role=app-aws` 成功，token 上挂 `db-readonly` policy
- [ ] `vault read database/creds/readonly` 成功，返回 `username`/`password`/`lease_id`
- [ ] PG 端 `pg_roles` 里能看到 `v-iam-readonly-...` 这个临时账号
- [ ] 用临时账号能 `SELECT * FROM demo.kv` 拿到业务数据
- [ ] `vault lease revoke` 后 PG 端账号消失、用临时凭据登录失败

> **关键观察**：到这里，`database/config/postgres-broker` 与
> `database/roles/readonly` 已经是"通用下游"——**任何**通过 Phase 1+2
> 拿到合法 Vault token 的调用方都能调它。第二步会换上 K8s ServiceAccount
> 作为 Phase 1 的认证方法，**第二步全程不会动这两条 PG 配置**。
