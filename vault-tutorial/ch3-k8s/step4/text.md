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
CRED=$(vault write -format=json kubernetes/creds/mode-c kubernetes_namespace=default)
TOKEN=$(echo "$CRED" | jq -r .data.service_account_token)
SA=$(echo "$CRED" | jq -r .data.service_account_name)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "临时 SA: $SA"
kubectl get role/"$SA" rolebinding/"$SA" sa/"$SA" -n default
```

应同时看到三个同名临时对象：Role、RoleBinding、ServiceAccount。
Vault 默认会用同一个生成名创建这三件套，名称形如 `v-<调用者>-mode-c-<时间戳>-<随机串>`。

```bash
# 看现场生成的 Role 的具体规则
kubectl describe role "$SA" -n default
```

## 4.3 验证权限严格符合声明

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

kc_token -n default auth can-i get secrets       # yes
kc_token -n default auth can-i list configmaps   # yes
kc_token -n default auth can-i delete secrets    # no  (verbs 没 delete)
kc_token -n default auth can-i list pods         # no  (resources 没 pods)
```

## 4.4 revoke → 三件套全消失

```bash
vault lease revoke "$LEASE"
sleep 1
kubectl get role/"$SA" rolebinding/"$SA" sa/"$SA" -n default 2>/dev/null || echo "(三件套已全部清理)"
```

## 4.5 三种模式的清理边界对照实验

```bash
# 同时持有 A / B / C 三个 lease
LA=$(vault write -format=json kubernetes/creds/mode-a kubernetes_namespace=default | jq -r .lease_id)
LB=$(vault write -format=json kubernetes/creds/mode-b kubernetes_namespace=default | jq -r .lease_id)
LC=$(vault write -format=json kubernetes/creds/mode-c kubernetes_namespace=default | jq -r .lease_id)

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

- [ ] 申领后 `default` ns 同时多了同名临时 Role、RoleBinding、SA（名称包含 `mode-c`）
- [ ] 使用 token-only 的 `kubectl` 验证权限严格匹配 rules：can secrets/configmaps get/list；不能 delete/list pods
- [ ] revoke 后三件套**全部消失**
- [ ] 对照实验显示：A 不删任何对象；B 删 2 个（SA + RB）；C 删 3 个（Role + RB + SA）
