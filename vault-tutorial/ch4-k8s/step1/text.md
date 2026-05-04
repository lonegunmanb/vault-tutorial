# 第一步：启用 kubernetes auth 并配置 TokenReview

Kubernetes auth 必须先启用并配置，Vault 才能接受 Pod 或 ServiceAccount 提交的 JWT；本实验选择显式提供 Kubernetes API server 地址、CA 证书以及用于调用 TokenReview API 的 reviewer token。

## 1.1 创建 reviewer ServiceAccount

先创建一个专门给 Vault 调用 TokenReview 的 ServiceAccount：

```bash
kubectl create namespace vault-system
kubectl create serviceaccount vault-reviewer -n vault-system
```

在启用 RBAC 的集群中，reviewer ServiceAccount 需要访问 TokenReview API；HashiCorp 文档示例使用内置 `system:auth-delegator` ClusterRole 授权。

```bash
kubectl create clusterrolebinding vault-reviewer-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-system:vault-reviewer
```

## 1.2 生成 reviewer JWT 与 Kubernetes 连接参数

本实验使用 `kubectl create token` 为 reviewer ServiceAccount 生成一枚短生命期 token；Kubernetes 官方推荐 TokenRequest 这类短生命期 token，因为它可以自动过期并避免长期 bearer token 的泄露风险。

```bash
REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-system --duration=1h)
K8S_HOST=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
K8S_CA_CERT=/tmp/k8s-ca.crt
kubectl config view --raw --minify -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$K8S_CA_CERT"

echo "$K8S_HOST"
echo "$REVIEWER_JWT" | cut -c 1-40 && echo "..."
ls -l "$K8S_CA_CERT"
```

`K8S_HOST` 是 Kubernetes API server 的地址，`K8S_CA_CERT` 是保存 CA 证书的本地文件路径，`REVIEWER_JWT` 是 Vault 调用 TokenReview API 时使用的 bearer token。

## 1.3 启用 Kubernetes 认证方法

默认挂载路径是 `auth/kubernetes/`，后续所有命令都按默认路径书写。

```bash
vault auth enable kubernetes
vault auth list | grep kubernetes
vault auth list -format=json | jq -r '."kubernetes/".accessor'
```

`vault auth list` 的普通输出没有表头，容易看漏字段。以 `kubernetes/    kubernetes    auth_kubernetes_8c380951    n/a    n/a` 为例，第三列 `auth_kubernetes_8c380951` 就是 accessor。最后一条 JSON 命令会只打印 accessor 本身，后续模板化策略会用到这个值。

## 1.4 写入 `auth/kubernetes/config`

把 reviewer JWT、API server 地址与 CA 证书写入配置端点：

```bash
vault write auth/kubernetes/config \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@"$K8S_CA_CERT"
```

回读配置时，Vault 不会回显 reviewer JWT 的明文，而是用 `token_reviewer_jwt_set` 表示是否已配置凭据。

```bash
vault read auth/kubernetes/config
```

应看到 `token_reviewer_jwt_set    true`，并能看到 `kubernetes_host` 与 CA 相关配置。

## 1.5 这一步的核心闭环

到这里，Vault 已经具备调用 Kubernetes TokenReview API 的能力；下一步将创建实际登录用的 `demo/myapp` ServiceAccount，并把它映射到一个 Vault role。
