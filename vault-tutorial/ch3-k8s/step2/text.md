# 第 2 步：模式 A `service_account_name` —— 借用现有 SA

模型：[3.11 §4.1](/ch3-k8s)。本步要：

1. 用 `service_account_name="viewer-sa"` 创建 Vault Role
2. 申领 token，用一个**只带该 token、不带 admin 证书**的 `kubectl` 调用验证它的权限恰好是 `pod-reader` Role 给的
3. revoke Lease，观察 K8s 上 **没有任何对象被删除**——因为模式 A 没有创建临时对象；已签出的短期 token 会按自身 `exp` 自然过期

---

## 2.1 看清预置资源

```bash
kubectl get sa viewer-sa -n default
kubectl describe rolebinding viewer-binding -n default
```

`viewer-binding` 把 `viewer-sa` 绑到了 `pod-reader` Role（仅 `pods:get,list`）。

## 2.2 创建 Vault Role

```bash
vault write kubernetes/roles/mode-a \
  allowed_kubernetes_namespaces="default" \
  service_account_name="viewer-sa" \
  token_default_ttl="10m" \
  token_max_ttl="1h"

vault read kubernetes/roles/mode-a
```

## 2.3 申领 + 验证权限

```bash
CRED=$(vault write -format=json kubernetes/creds/mode-a kubernetes_namespace=default)
TOKEN=$(echo "$CRED" | jq -r .data.service_account_token)
LEASE=$(echo "$CRED" | jq -r .lease_id)
SA=$(echo "$CRED" | jq -r .data.service_account_name)

echo "Token 颁给的 SA: $SA"
echo "Lease ID: $LEASE"
```

> 注意：Killercoda 预置的 kubeconfig 通常带有集群管理员 client certificate。
> 如果只写 `kubectl --token="$TOKEN" ...`，kubectl 仍可能同时带上管理员证书，API Server 会把你识别成管理员，于是 `list secrets` 也会返回 `yes`。
> 下面先创建一个空 kubeconfig，再只带本次签出的 token 来验证权限。

```bash
K8S_SERVER=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
TOKEN_KUBECONFIG=/tmp/vault-k8s-token-only.conf
: > "$TOKEN_KUBECONFIG"

kc_token() {
  kubectl --kubeconfig="$TOKEN_KUBECONFIG" \
    --server="$K8S_SERVER" \
    --insecure-skip-tls-verify=true \
    --token="$TOKEN" "$@"
}

# 应输出 yes（pod-reader 给了 list pods）
kc_token -n default auth can-i list pods

# 应输出 no（pod-reader 没给 secrets 权限）
kc_token -n default auth can-i list secrets
```

## 2.4 revoke 后观察 K8s 状态

记下当前的 SA / Role / RoleBinding 数量：

```bash
kubectl get sa,role,rolebinding -n default
```

```bash
vault lease revoke "$LEASE"
sleep 1
kubectl get sa,role,rolebinding -n default
```

数量**完全没变**。模式 A 没有任何临时对象需要清理。

注意：模式 A 借用的是已有 `viewer-sa`，Vault revoke lease 时无法删除这个已有 SA，也不会主动撤销单个 TokenRequest token。
所以刚刚签出的 token 通常会继续有效，直到 JWT 自己的 `exp` 到期。
你可以解码 token 看它的过期时间：

```bash
PAYLOAD=$(echo "$TOKEN" | cut -d'.' -f2 | tr '_-' '/+')
PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $(( (4 - ${#PAYLOAD} % 4) % 4 ))))"
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.iat,.exp | todate'
```

---

## ✅ 验收

- [ ] `vault write kubernetes/creds/mode-a kubernetes_namespace=default` 返回 `service_account_name: viewer-sa`
- [ ] 使用 token-only 的 `kubectl` 验证权限：`list pods` = yes，`list secrets` = no
- [ ] revoke 后 K8s 上 SA / Role / RoleBinding 数量不变
- [ ] 已理解：模式 A 的短期 token 不会被提前撤销，只会随 JWT `exp` 自然过期
