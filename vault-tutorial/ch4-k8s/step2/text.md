# 第二步：创建 myapp ServiceAccount 并登录 Vault

![Step 2 故事板：myapp 拿短期工牌，经 Vault 门禁换取保险柜通行证](../assets/step2-myapp-login-story.svg)

> 绘图提示词：手绘风格，现实事物比喻风格，彩色横向故事板，分成 6 个从左到右的小画面。第 1 格画 Kubernetes 园区里的 `demo` 办公室，新员工 `myapp` 领取 ServiceAccount 工牌；第 2 格画 Vault 保险柜里放入 `secret/demo/myapp/config` 文件夹；第 3 格画管理员给 Vault 门禁写一张 `myapp-read` 权限纸条，只允许读取自己的文件夹；第 4 格画 Vault 门禁登记 role，门禁牌上写着“只认 demo/myapp，入场目的必须是 vault-demo”；第 5 格画 Kubernetes 发给 `myapp` 一张 10 分钟有效的短期 JWT 工牌；第 6 格画 `myapp` 拿 JWT 到 Vault 门禁核验，Vault 问 Kubernetes TokenReview 确认身份后，发一张受 policy 限制的 Vault token，最后只能打开自己的保险柜文件夹。对话气泡必须明确方向：所有气泡尾巴连接到说话者，气泡朝向或小箭头指向接收者；第 4 格管理员对 Vault 门禁说“登记 role：只认 demo/myapp”；第 5 格 Kubernetes API server 对 `myapp` 说“给你 10 分钟 JWT”；第 6 格依次画 `myapp` 对 Vault 说“我用 role=myapp 登录”，Vault 对 Kubernetes TokenReview 说“请核验这张 JWT”，Kubernetes 对 Vault 回答“是 demo/myapp，audience=vault-demo”，Vault 对 `myapp` 说“给你受限 Vault token”。整体像纸笔手绘教程图，线条朴素，颜色明快但不花哨，箭头清楚标出命令执行顺序，重点让初学者看懂“创建身份、写 secret、写 policy、写 role、生成 JWT、登录并读 secret”的闭环。

这一节把 Kubernetes auth 的主路径完整跑通：创建一个 `demo/myapp` ServiceAccount，给它签发一枚 audience 为 `vault-demo` 的短生命期 JWT，再通过 `auth/kubernetes/login` 换取 Vault token。

## 2.1 准备应用 ServiceAccount 与教学用 secret

创建 `demo` namespace 与 `myapp` ServiceAccount；ServiceAccount 是 Kubernetes 中面向工作负载的非人类身份，Pod 可以使用它的凭据代表自身访问 Kubernetes API 或外部系统。

```bash
kubectl create namespace demo
kubectl create serviceaccount myapp -n demo
```

Vault Dev 模式通常已经启用了 `secret/` KV v2；下面写入一个只给 `myapp` 读取的教学 secret。

```bash
vault kv put secret/demo/myapp/config username=myapp password=learn-vault
```

## 2.2 创建 Vault policy

Kubernetes auth 登录成功后得到的是 Vault token，真正决定它能读写什么的是 Vault policy；这里创建一个只允许读取 `secret/demo/myapp/config` 的 policy。

```bash
cat > myapp-read.hcl <<'EOF'
path "secret/data/demo/myapp/config" {
  capabilities = ["read"]
}
EOF

vault policy write myapp-read myapp-read.hcl
```

## 2.3 创建 Kubernetes auth role

这个 role 只允许 `demo` namespace 中名为 `myapp` 的 ServiceAccount 登录，并要求 JWT 的 audience 为 `vault-demo`。

```bash
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=demo \
  audience=vault-demo \
  token_policies=myapp-read \
  token_ttl=15m
```

回读 role，确认 name、namespace、audience 与 policy 均已写入。

```bash
vault read auth/kubernetes/role/myapp
```

## 2.4 给 myapp 签发一枚短生命期 JWT

使用 TokenRequest 方式生成的 ServiceAccount token 可以带有有效期与 audience；Kubernetes 官方推荐这种短生命期 token，而不是长期 Secret token。

```bash
MYAPP_JWT=$(kubectl create token myapp -n demo --audience=vault-demo --duration=10m)
echo "$MYAPP_JWT" | cut -c 1-60 && echo "..."
```

## 2.5 登录 Vault

登录端点需要两个字段：Vault role 名称与 Kubernetes ServiceAccount JWT。

```bash
LOGIN_JSON=$(vault write -format=json auth/kubernetes/login role=myapp jwt="$MYAPP_JWT")
echo "$LOGIN_JSON" | jq '.auth | {policies, metadata, lease_duration, renewable}'
APP_VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r '.auth.client_token')
```

输出中的 metadata 应包含 `service_account_name: myapp`、`service_account_namespace: demo` 与 `service_account_uid`；这些字段来自 Kubernetes TokenReview 返回的身份信息，并写入 Vault 登录响应。

官方示例响应中还展示了 `service_account_secret_name`；本实验使用 TokenRequest 方式生成短生命期 token，通常不会关联长期 Secret，因此该字段可能为空或不出现。

## 2.6 使用新 token 读取 secret

用登录得到的 Vault token 读取刚才写入的 KV 数据：

```bash
VAULT_TOKEN="$APP_VAULT_TOKEN" vault kv get secret/demo/myapp/config
```

如果返回 `username` 与 `password` 字段，说明 Kubernetes ServiceAccount JWT 已成功转换成受 `myapp-read` policy 约束的 Vault token。

## 2.7 这一步的核心闭环

这一节验证了 Kubernetes auth 的主链路：ServiceAccount JWT 经过 TokenReview 认证，命中 Vault role 约束后得到 Vault token，而 Vault token 的能力由 role 上绑定的 policy 决定。
