# 第四步：使用注解 metadata 与模板化策略

官方工作流展示了一种更细的授权模式：把 Kubernetes ServiceAccount 注解写入 Vault Identity alias metadata，再在 Vault templated policy 中引用这些 metadata，让不同 ServiceAccount 自动落到不同 secret 路径。

## 4.1 给 ServiceAccount 添加 alias metadata 注解

Vault 只读取以 `vault.hashicorp.com/alias-metadata-` 为前缀的注解；下面的注解会把 metadata key `env` 设置为 `demo/myapp`。

```bash
kubectl annotate serviceaccount myapp -n demo \
  vault.hashicorp.com/alias-metadata-env=demo/myapp \
  --overwrite

kubectl get serviceaccount myapp -n demo -o yaml | grep alias-metadata
```

## 4.2 启用注解到 alias metadata 的映射

重新写入 Kubernetes auth 配置，并打开 `use_annotations_as_alias_metadata=true`；因为配置端点包含 Kubernetes API 连接信息，所以这里保留 Step 1 中的 `REVIEWER_JWT`、`K8S_HOST` 与 `K8S_CA_CERT`。

```bash
vault write auth/kubernetes/config \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@"$K8S_CA_CERT" \
  use_annotations_as_alias_metadata=true

vault read auth/kubernetes/config | grep use_annotations_as_alias_metadata
```

启用该选项后，Vault 在登录过程中需要读取客户端 JWT 对应的 ServiceAccount 对象；第三步已授予 reviewer ServiceAccount 读取 `serviceaccounts` 的权限。

## 4.3 创建 templated policy

templated policy 需要使用 Kubernetes auth mount 的 accessor；官方示例通过 `vault auth list` 或 `sys/auth` 获取 accessor，并在 policy 路径中引用 `identity.entity.aliases.<mount accessor>.metadata.<metadata key>`。

```bash
ACCESSOR=$(vault auth list -format=json | jq -r '."kubernetes/".accessor')
echo "$ACCESSOR"

cat > env-tmpl.hcl <<EOF
path "secret/data/{{identity.entity.aliases.$ACCESSOR.metadata.env}}/config" {
  capabilities = ["read"]
}
EOF

cat env-tmpl.hcl
vault policy write env-tmpl env-tmpl.hcl
```

如果 `myapp` 登录时 alias metadata 中的 `env` 等于 `demo/myapp`，这条 policy 会渲染为 `secret/data/demo/myapp/config`。

## 4.4 创建使用模板化策略的 role

创建一个新的 Vault role，让 `demo/myapp` 登录后只获得 `env-tmpl` policy。

```bash
vault write auth/kubernetes/role/env-reader \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=demo \
  audience=vault-demo \
  token_policies=env-tmpl \
  token_ttl=15m
```

## 4.5 登录并验证模板渲染后的读取权限

重新给 `myapp` 生成 token，登录 `env-reader` role，并用返回的 Vault token 读取 secret。

```bash
MYAPP_JWT2=$(kubectl create token myapp -n demo --audience=vault-demo --duration=10m)
ENV_LOGIN_JSON=$(vault write -format=json auth/kubernetes/login role=env-reader jwt="$MYAPP_JWT2")
ENV_TOKEN=$(echo "$ENV_LOGIN_JSON" | jq -r '.auth.client_token')

VAULT_TOKEN="$ENV_TOKEN" vault kv get secret/demo/myapp/config
```

如果读取成功，说明 Kubernetes ServiceAccount 注解已经进入 Vault Identity alias metadata，并被 templated policy 用于计算实际可访问路径。

## 4.6 反向验证：otherapp 登录后仍不能读取 myapp 路径

`otherapp` 没有 `vault.hashicorp.com/alias-metadata-env` 注解；为了观察模板化 policy 的效果，先创建一个允许 `demo` namespace 内任意 ServiceAccount 登录、但仍只绑定 `env-tmpl` policy 的 role。

```bash
vault write auth/kubernetes/role/env-any \
  bound_service_account_names='*' \
  bound_service_account_namespaces=demo \
  audience=vault-demo \
  token_policies=env-tmpl \
  token_ttl=15m

OTHER_ENV_JSON=$(vault write -format=json auth/kubernetes/login role=env-any jwt="$OTHER_JWT")
OTHER_ENV_TOKEN=$(echo "$OTHER_ENV_JSON" | jq -r '.auth.client_token')
echo "$OTHER_ENV_JSON" | jq '.auth.metadata'
```

登录可以成功，因为 `env-any` 允许该 namespace 中任意 ServiceAccount；但读取 `myapp` 的路径应失败，因为 `otherapp` 没有提供让 `env-tmpl` 渲染到 `demo/myapp` 的 alias metadata。

```bash
VAULT_TOKEN="$OTHER_ENV_TOKEN" vault kv get secret/demo/myapp/config
```

## 4.7 收尾清理

禁用一个 auth method 会移除该 mount 下的配置与 role，并使通过该 auth method 签发的 token 失效；这适合实验结束时恢复环境。

```bash
vault auth disable kubernetes || true
kubectl delete namespace demo blocked vault-system --ignore-not-found=true
kubectl delete clusterrolebinding vault-reviewer-tokenreview vault-kubernetes-auth-read --ignore-not-found=true
kubectl delete clusterrole vault-kubernetes-auth-read --ignore-not-found=true
```

## 4.8 这一步的核心闭环

ServiceAccount 注解可以在登录时进入 Vault Identity alias metadata，templated policy 可以读取这些 metadata 并渲染出实际授权路径；这让同一个 Vault role 与同一份 policy 能服务多个工作负载，同时把路径差异保留在 Kubernetes ServiceAccount 对象上。
