# 第二步：创建 myapp ServiceAccount 并登录 Vault

这一节把 Kubernetes auth 的主路径完整跑通：创建一个 `demo/myapp` ServiceAccount，给它签发一枚 audience 为 `vault-demo` 的短生命期 JWT，再通过 `auth/kubernetes/login` 换取 Vault token。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Authentication；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

## 2.1 准备应用 ServiceAccount 与教学用 secret

创建 `demo` namespace 与 `myapp` ServiceAccount；ServiceAccount 是 Kubernetes 中面向工作负载的非人类身份，Pod 可以使用它的凭据代表自身访问 Kubernetes API 或外部系统。 [来源：Kubernetes 官方文档《Service Accounts》§What are service accounts?；Kubernetes 官方文档《Service Accounts》§Use cases for Kubernetes service accounts]

```bash
kubectl create namespace demo
kubectl create serviceaccount myapp -n demo
```

Vault Dev 模式通常已经启用了 `secret/` KV v2；下面写入一个只给 `myapp` 读取的教学 secret。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Workflows / Working with templated policies]

```bash
vault kv put secret/demo/myapp/config username=myapp password=learn-vault
```

## 2.2 创建 Vault policy

Kubernetes auth 登录成功后得到的是 Vault token，真正决定它能读写什么的是 Vault policy；这里创建一个只允许读取 `secret/demo/myapp/config` 的 policy。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuration；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Create/Update role]

```bash
cat > myapp-read.hcl <<'EOF'
path "secret/data/demo/myapp/config" {
  capabilities = ["read"]
}
EOF

vault policy write myapp-read myapp-read.hcl
```

## 2.3 创建 Kubernetes auth role

这个 role 只允许 `demo` namespace 中名为 `myapp` 的 ServiceAccount 登录，并要求 JWT 的 audience 为 `vault-demo`。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuration；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Create/Update role / Parameters]

```bash
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=demo \
  audience=vault-demo \
  token_policies=myapp-read \
  token_ttl=15m
```

回读 role，确认 name、namespace、audience 与 policy 均已写入。 [来源：HashiCorp Vault API 文档《Kubernetes auth method (API)》§Read role]

```bash
vault read auth/kubernetes/role/myapp
```

## 2.4 给 myapp 签发一枚短生命期 JWT

使用 TokenRequest 方式生成的 ServiceAccount token 可以带有有效期与 audience；Kubernetes 官方推荐这种短生命期 token，而不是长期 Secret token。 [来源：Kubernetes 官方文档《Service Accounts》§How to use service accounts / Manually retrieve ServiceAccount credentials]

```bash
MYAPP_JWT=$(kubectl create token myapp -n demo --audience=vault-demo --duration=10m)
echo "$MYAPP_JWT" | cut -c 1-60 && echo "..."
```

## 2.5 登录 Vault

登录端点需要两个字段：Vault role 名称与 Kubernetes ServiceAccount JWT。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Authentication / Via the API；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

```bash
LOGIN_JSON=$(vault write -format=json auth/kubernetes/login role=myapp jwt="$MYAPP_JWT")
echo "$LOGIN_JSON" | jq '.auth | {policies, metadata, lease_duration, renewable}'
APP_VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r '.auth.client_token')
```

输出中的 metadata 应包含 `service_account_name: myapp`、`service_account_namespace: demo` 与 `service_account_uid`；这些字段来自 Kubernetes TokenReview 返回的身份信息，并写入 Vault 登录响应。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Authentication / Via the API；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

官方示例响应中还展示了 `service_account_secret_name`；本实验使用 TokenRequest 方式生成短生命期 token，通常不会关联长期 Secret，因此该字段可能为空或不出现。 [来源：HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login / Sample response；Kubernetes 官方文档《Service Accounts》§How to use service accounts / Manually retrieve ServiceAccount credentials]

## 2.6 使用新 token 读取 secret

用登录得到的 Vault token 读取刚才写入的 KV 数据： [来源：HashiCorp Vault 文档《Kubernetes auth method》§Authentication / Via the API]

```bash
VAULT_TOKEN="$APP_VAULT_TOKEN" vault kv get secret/demo/myapp/config
```

如果返回 `username` 与 `password` 字段，说明 Kubernetes ServiceAccount JWT 已成功转换成受 `myapp-read` policy 约束的 Vault token。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuration；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

## 2.7 这一步的核心闭环

这一节验证了 Kubernetes auth 的主链路：ServiceAccount JWT 经过 TokenReview 认证，命中 Vault role 约束后得到 Vault token，而 Vault token 的能力由 role 上绑定的 policy 决定。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuring kubernetes；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Create/Update role；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]
