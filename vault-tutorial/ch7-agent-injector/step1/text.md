# 第一步：安装 Injector 并准备基线 Pod

后台只准备了 Vault CLI、Helm 和后续 YAML。本实验演示的 Vault dev server 与 Vault Agent Injector 需要你在这一步用 Helm 安装。

先添加 HashiCorp Helm 仓库，然后安装启用了 Injector 的 Vault dev server。

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set='server.dev.enabled=true' \
  --set='server.dev.devRootToken=root' \
  --set='injector.enabled=true' \
  --set='injector.metrics.enabled=true' \
  --wait \
  --timeout=5m

kubectl -n vault rollout status deployment/vault-agent-injector --timeout=180s
```

创建本实验的应用 namespace 与 ServiceAccount。`demo/webapp` 是稍后被注入 Pod 使用的身份；`vault-agent-injector-init` 是一次性初始化 Job 使用的临时身份。

```bash
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n demo create serviceaccount webapp --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vault create serviceaccount vault-agent-injector-init --dry-run=client -o yaml | kubectl apply -f -
```

授权 Vault server Pod 的 ServiceAccount 调用 Kubernetes TokenReview API。Vault Kubernetes auth method 后续会用它校验应用 Pod 提交的 ServiceAccount token。

```bash
VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}')
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"

kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

现在运行课程准备的初始化脚本。它会创建一个 Kubernetes Job，通过集群内 Vault Pod DNS 配置 Vault 的 Kubernetes auth method、写入 KV v2 机密，并创建只允许 `demo/webapp` 登录的 Vault role `webapp`。

```bash
/root/configure-vault-agent-injector.sh
```

确认 Vault Agent Injector 已经部署出来，且 admission webhook 已注册。

```bash
kubectl -n vault get pods
kubectl -n vault get deployment vault-agent-injector
kubectl get mutatingwebhookconfigurations | grep vault
```

确认 Vault 中已经存在本实验的 Kubernetes auth role 与 KV v2 机密。下面的 Vault CLI 命令是在 controlplane 上执行的，因此先手动建立到集群内 Vault Service 的端口转发；这一步只用于本地 CLI 访问，不负责初始化 Vault。

```bash
ensure-vault-port-forward
vault status
vault read auth/kubernetes/role/webapp
vault kv get secret/injector/web
kubectl -n demo get serviceaccount webapp
```

现在先部署一个没有任何 Injector annotation 的基线 Deployment。

```bash
kubectl -n demo apply -f /root/baseline.yaml
kubectl -n demo rollout status deployment/baseline
BASELINE_POD=$(kubectl -n demo get pod -l app=baseline -o jsonpath='{.items[0].metadata.name}')
echo "$BASELINE_POD"
```

查看这个 Pod 的容器列表与 volume 列表。因为它没有 `vault.hashicorp.com/agent-inject: "true"`，所以不会出现 `vault-agent-init`、`vault-agent` 或 `/vault/secrets` 相关 volume。

```bash
kubectl -n demo get pod "$BASELINE_POD" -o json | jq -r '.spec.containers[].name'
kubectl -n demo get pod "$BASELINE_POD" -o json | jq -r '.spec.volumes[]?.name'
```

这一步建立了对照组：Injector 已经安装，但只有带有正确 Pod template annotation 的工作负载才会被改写。