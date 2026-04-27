# 第 2 步：模式 A `service_account_name` —— 借用现有 SA

模型：[3.11 §4.1](/ch3-k8s)。本步要：

1. 用 `service_account_name="viewer-sa"` 创建 Vault Role
2. 申领 token，用 `kubectl --token=...` 验证它的权限恰好是 `pod-reader` Role 给的
3. revoke Lease，观察 K8s 上 **没有任何对象被删除**——因为模式 A 没有创建临时对象

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
CRED=$(vault read -format=json kubernetes/creds/mode-a)
TOKEN=$(echo "$CRED" | jq -r .data.service_account_token)
LEASE=$(echo "$CRED" | jq -r .lease_id)
SA=$(echo "$CRED" | jq -r .data.service_account_name)

echo "Token 颁给的 SA: $SA"
echo "Lease ID: $LEASE"
```

```bash
# 应输出 yes（pod-reader 给了 list pods）
kubectl --token="$TOKEN" -n default auth can-i list pods

# 应输出 no（pod-reader 没给 secrets 权限）
kubectl --token="$TOKEN" -n default auth can-i list secrets
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

不过 token 已经被 K8s 记下"该 SA 在某个时点之前签的 token 才算"——简单的验证：

```bash
kubectl --token="$TOKEN" -n default auth can-i list pods
```

会返回 `no` 或报错（token 已过 Vault 的 TTL；K8s 端的撤销由 token 自带 expiry 实现）。

---

## ✅ 验收

- [ ] `vault read kubernetes/creds/mode-a` 返回 `service_account_name: viewer-sa`
- [ ] `kubectl --token` 验证权限：`list pods` = yes，`list secrets` = no
- [ ] revoke 后 K8s 上 SA / Role / RoleBinding 数量不变
- [ ] revoke 后 token 已不再有效
