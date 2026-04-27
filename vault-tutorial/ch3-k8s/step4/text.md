# 第 4 步：模式 C `generated_role_rules` —— Role + RoleBinding + SA 三件套全量现场生成

模型：[3.11 §4.3](/ch3-k8s)。本步要：

1. 创建 Vault Role，**直接在 Vault 里写死 K8s Role 的 rules**
2. 申领 token；K8s 上多出 **3 个**临时对象
3. 验证 token 权限严格符合声明的 rules
4. revoke → 三件套**全部消失**
5. 用对照实验观察 A / B / C 三种模式清理边界的差异

---

## 4.1 创建 Vault Role（带 rules）

```bash
vault write kubernetes/roles/mode-c \
  allowed_kubernetes_namespaces="default" \
  generated_role_rules='rules:
  - apiGroups: [""]
    resources: ["secrets","configmaps"]
    verbs: ["get","list"]' \
  token_default_ttl="10m"

vault read kubernetes/roles/mode-c
```

## 4.2 申领 + 看 K8s 三件套

```bash
CRED=$(vault read -format=json kubernetes/creds/mode-c kubernetes_namespace=default)
TOKEN=$(echo "$CRED" | jq -r .data.service_account_token)
SA=$(echo "$CRED" | jq -r .data.service_account_name)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "临时 SA: $SA"
kubectl get role,rolebinding,sa -n default | grep -E "^role.*v-role|^rolebinding.*v-binding|^serviceaccount/v-token"
```

应同时看到三个临时对象：`v-role-mode-c-*`、`v-binding-mode-c-*`、`v-token-mode-c-*`。

```bash
# 看现场生成的 Role 的具体规则
kubectl describe role -n default | awk '/^Name:.*v-role/,/^Events:/'
```

## 4.3 验证权限严格符合声明

```bash
kubectl --token="$TOKEN" -n default auth can-i get secrets       # yes
kubectl --token="$TOKEN" -n default auth can-i list configmaps   # yes
kubectl --token="$TOKEN" -n default auth can-i delete secrets    # no  (verbs 没 delete)
kubectl --token="$TOKEN" -n default auth can-i list pods         # no  (resources 没 pods)
```

## 4.4 revoke → 三件套全消失

```bash
vault lease revoke "$LEASE"
sleep 1
kubectl get role,rolebinding,sa -n default | grep -E "v-role|v-binding|v-token" || echo "(三件套已全部清理)"
```

## 4.5 三种模式的清理边界对照实验

```bash
# 同时持有 A / B / C 三个 lease
LA=$(vault read -format=json kubernetes/creds/mode-a | jq -r .lease_id)
LB=$(vault read -format=json kubernetes/creds/mode-b kubernetes_namespace=default | jq -r .lease_id)
LC=$(vault read -format=json kubernetes/creds/mode-c kubernetes_namespace=default | jq -r .lease_id)

count() { kubectl get sa,role,rolebinding -n default --no-headers 2>/dev/null | wc -l; }
echo "三个 lease 全活: $(count) 个对象"

vault lease revoke "$LA"; sleep 1
echo "revoke A 后  : $(count)  (A 没临时对象，应不变)"

vault lease revoke "$LB"; sleep 1
echo "revoke B 后  : $(count)  (B 删 SA + RoleBinding，应少 2)"

vault lease revoke "$LC"; sleep 1
echo "revoke C 后  : $(count)  (C 删 Role + RoleBinding + SA，应少 3)"
```

---

## ✅ 验收

- [ ] 申领后 `default` ns 同时多了 `v-role-mode-c-*` Role、`v-binding-mode-c-*` RB、`v-token-mode-c-*` SA
- [ ] `kubectl --token` 验证权限严格匹配 rules：can secrets/configmaps get/list；不能 delete/list pods
- [ ] revoke 后三件套**全部消失**
- [ ] 对照实验显示：A 不删任何对象；B 删 2 个（SA + RB）；C 删 3 个（Role + RB + SA）
