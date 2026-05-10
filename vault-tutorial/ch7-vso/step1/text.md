# 第一步：安装 VSO 并准备实验身份

后台只准备了 Vault CLI、Helm 和常用工具。本实验演示的 Vault dev server、Vault Secrets Operator，以及应用 namespace / ServiceAccount 都需要你在这一步安装和创建。

先添加 HashiCorp Helm 仓库。

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

安装 dev 模式 Vault Server。本实验聚焦 VSO，所以关闭 Vault Helm chart 中的 Injector 与 CSI provider。

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "csi.enabled=false" \
  --set "injector.enabled=false" \
  --wait \
  --timeout=5m

kubectl -n vault rollout status statefulset/vault --timeout=180s
```

创建本实验的应用 namespace 与 ServiceAccount。`vso-demo/vso-app` 是稍后 `VaultAuth` 指定的 Kubernetes 身份；`vault-vso-init` 是一次性初始化 Job 使用的临时身份。

```bash
kubectl create namespace vso-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vso-demo create serviceaccount vso-app --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vault create serviceaccount vault-vso-init --dry-run=client -o yaml | kubectl apply -f -
```

授权 Vault server Pod 的 ServiceAccount 调用 Kubernetes TokenReview API。VSO 后续会为 `VaultAuth` 中指定的 ServiceAccount 请求 token，再让 Vault 校验这个 token。

```bash
VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}')
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"

kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

安装 Vault Secrets Operator。Helm chart 会安装控制器和 `secrets.hashicorp.com/v1beta1` 相关 CRD。

```bash
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator \
  --create-namespace \
  --version 0.10.0 \
  --wait \
  --timeout=5m

kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout=240s
```

运行课程准备的初始化脚本。它会创建一个 Kubernetes Job，在 Vault 中配置 Kubernetes auth method、写入 `secret/vso/app`，创建 policy 与 Vault role `vso-app`，并生成后续步骤使用的 VSO 清单。

```bash
/root/configure-vault-vso.sh
```

确认 Kubernetes 节点、Vault Pod、VSO 控制器 Pod 均处于 Ready / Running 状态。

```bash
kubectl get nodes
kubectl get pods -n vault -o wide
kubectl get pods -n vault-secrets-operator
```

确认 VSO 提供的 CRD 已经注册。所有 CRD 都属于同一个 API group `secrets.hashicorp.com/v1beta1`。

```bash
kubectl get crd | grep secrets.hashicorp.com
```

查看 Vault 中的 KV v2 数据。该机密保存在挂载点 `secret`、路径 `vso/app` 下，最终 API 端点是 `secret/data/vso/app`。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault kv get secret/vso/app'
```

查看 Kubernetes auth role：它仅绑定 `vso-demo` namespace 下名为 `vso-app` 的 ServiceAccount，并要求 token audience 为 `vault`。这与稍后 `VaultAuth` 中的 `audiences` 必须保持一致。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault read auth/kubernetes/role/vso-app'
```

确认 `vso-demo` namespace 与 `vso-app` ServiceAccount 已存在。

```bash
kubectl get ns vso-demo
kubectl -n vso-demo get sa vso-app
```