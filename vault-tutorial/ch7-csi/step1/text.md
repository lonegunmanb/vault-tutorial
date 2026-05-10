# 第一步：安装 CSI 组件并准备实验身份

这一页是“准备舞台”。你会安装两个 Kubernetes 平台组件，并创建后面应用 Pod 使用的身份：

- Secrets Store CSI driver：Kubernetes 侧的通用 CSI driver，负责处理 Pod 的 CSI volume 挂载请求。
- Vault Secrets Store CSI provider：Vault 专用 provider，负责根据 `SecretProviderClass` 登录 Vault、读取机密并交给 CSI driver。
- Vault dev server：实验用 Vault 服务，里面会写入一条 KV v2 机密。
- `csi-demo/app`：后续应用 Pod 使用的 Kubernetes ServiceAccount。

本步骤结束时，你不需要已经看到机密文件；那是第二步才会发生的事。本步骤的完成标志是：CSI driver、Vault provider、Vault Pod 都 Running，`SecretProviderClass` 这个 CRD 已经存在，并且 `/root/csi-file-mount.yaml` 等实验清单已经生成。

后台只准备了 Vault CLI、Helm 和常用工具。本实验演示的 Secrets Store CSI driver、Vault dev server 与 Vault Secrets Store CSI provider 需要你在这一步安装。

先添加 Helm 仓库。

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update
```

安装 Secrets Store CSI driver。这里打开 `syncSecret.enabled=true`，是为了第四步演示把 Vault 数据同步为 Kubernetes Secret；`enableSecretRotation=true` 用于启用轮转调谐能力。

```bash
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  --wait \
  --timeout=5m

kubectl -n kube-system rollout status daemonset/csi-secrets-store-secrets-store-csi-driver --timeout=180s
```

再通过 Vault Helm chart 安装 dev 模式 Vault Server，并启用 Vault Secrets Store CSI provider。

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "csi.enabled=true" \
  --set "injector.enabled=false" \
  --wait \
  --timeout=5m

kubectl -n vault rollout status statefulset/vault --timeout=180s
kubectl -n vault rollout status daemonset/vault-csi-provider --timeout=180s
```

创建本实验的应用 namespace 与 ServiceAccount。`csi-demo/app` 是后续挂载 CSI volume 的 Pod 身份；`vault-csi-init` 是一次性初始化 Job 使用的临时身份。

```bash
kubectl create namespace csi-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n csi-demo create serviceaccount app --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vault create serviceaccount vault-csi-init --dry-run=client -o yaml | kubectl apply -f -
```

授权 Vault server Pod 的 ServiceAccount 调用 Kubernetes TokenReview API。Vault provider 后续会以挂载请求 Pod 的 ServiceAccount token 登录 Vault，Vault 需要通过 TokenReview 校验这个 token。

```bash
VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}')
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"

kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

运行课程准备的初始化脚本。它会创建一个 Kubernetes Job，在 Vault 中配置 Kubernetes auth method、写入 `secret/csi/app`，创建 policy 与 Vault role `csi-app`，并生成后续步骤使用的实验清单。

这一步的 Job 做的是 Vault 端准备工作：把 `csi-demo/app` 这个 Kubernetes 身份绑定到 Vault role `csi-app`，并让这个 role 只能读取 `secret/csi/app`。后面 Pod 能不能挂载成功，关键就看它是不是用这个 ServiceAccount 身份发起请求。

```bash
/root/configure-vault-csi.sh
```

确认 Kubernetes 节点、Vault Pod 与 CSI 相关 Pod 均已就绪。

```bash
kubectl get nodes
kubectl get pods -n vault -o wide
kubectl get pods -n kube-system | grep -E 'csi|secrets-store'
```

查看 Secrets Store CSI driver 与 Vault provider 的 DaemonSet。CSI driver 负责接收 Pod volume 请求；Vault provider 负责处理 `provider: vault` 的 `SecretProviderClass`。

```bash
kubectl get daemonset -n kube-system | grep -E 'csi|secrets-store'
kubectl get daemonset -n vault
```

确认 `SecretProviderClass` CRD 已经存在，并查看当前集群支持的 API version。实验清单会自动使用 CRD 中被标记为 served 的版本。

```bash
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
```

查看实验生成的文件挂载清单。重点观察三处：`provider: vault`、`roleName: "csi-app"`、以及 `objects` 中的 `objectName`、`secretPath` 和 `secretKey`。

先不用完全读懂整份 YAML，只要先建立这个对应关系：`secretPath` 表示去 Vault 哪里读，`secretKey` 表示读响应里的哪个字段，`objectName` 表示最后在 Pod 里看到的文件名。

```bash
sed -n '1,140p' /root/csi-file-mount.yaml
```

最后确认 Vault 中已经有实验机密，并且 Kubernetes auth role 只绑定 `csi-demo` namespace 下名为 `app` 的 ServiceAccount。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault kv get secret/csi/app'
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault read auth/kubernetes/role/csi-app'
```