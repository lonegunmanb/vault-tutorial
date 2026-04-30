# 第 1 步：启用 kubernetes/ 引擎并验证 manager SA 连接

模型见 [3.11 §2 + §3](/ch3-k8s)。本步要：

1. 确认 `kubernetes/` 引擎已启用、`kubernetes/config` 已写好
2. 看清 `vault-manager` SA 的 ClusterRole 究竟有哪些权限
3. 通过一次最简单的 token 申领验证连接通路

---

## 1.1 引擎状态

```bash
vault secrets list | grep -E "Path|kubernetes"
vault read kubernetes/config
```

> `service_account_jwt` 字段不会回显，这是正常的（机密字段）。

## 1.2 看 manager SA 的权限

```bash
kubectl get sa vault-manager -n vault-system
kubectl describe clusterrolebinding vault-kubernetes-secrets-binding
kubectl describe clusterrole vault-kubernetes-secrets
```

注意输出中的 `bind` 和 `escalate` 两个 verb——它们是 K8s **反权限提升**保护下，
模式 C（`generated_role_rules`）能创建任意 Role 的关键。

> **核心理解**：以上权限是 **manager SA 的**（即 Vault 在 K8s 上能干什么），
> 与"申领出来的 token 持有什么权限"是**完全独立的两码事**。
> Token 的权限只受绑定的 Role/RoleBinding 控制。

## 1.3 用最简 Role 验证连接

```bash
vault write kubernetes/roles/connectivity-check \
  allowed_kubernetes_namespaces="default" \
  service_account_name="viewer-sa"

vault write kubernetes/creds/connectivity-check kubernetes_namespace=default
```

应返回 `lease_id` + `service_account_token` 等字段。这条命令成功 = Vault 能连通 K8s API + manager SA 至少有 `serviceaccounts/token:create`。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `kubernetes/`
- [ ] `kubectl describe clusterrole vault-kubernetes-secrets` 列出 `bind`/`escalate`
- [ ] `vault write kubernetes/creds/connectivity-check kubernetes_namespace=default` 返回了一条真实 SA token
