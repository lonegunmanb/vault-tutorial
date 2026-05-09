# 第一步：检查 VSO 控制器、CRD 与 Vault 配置

后台脚本已经安装了 Vault dev server 与 Vault Secrets Operator。先确认 Kubernetes 节点、Vault Pod、VSO 控制器 Pod 均处于 Ready / Running 状态。

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

查看后台脚本创建的 Kubernetes auth role：它仅绑定 `vso-demo` namespace 下名为 `vso-app` 的 ServiceAccount，并要求 token audience 为 `vault`。这与稍后 `VaultAuth` 中的 `audiences` 必须保持一致。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault read auth/kubernetes/role/vso-app'
```

确认 `vso-demo` namespace 与 `vso-app` ServiceAccount 已存在。

```bash
kubectl get ns vso-demo
kubectl -n vso-demo get sa vso-app
```
