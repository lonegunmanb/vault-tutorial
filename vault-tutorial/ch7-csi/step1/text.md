# 第一步：检查 CSI 组件与 CRD

本实验的后台脚本已经安装了 Secrets Store CSI driver，并通过 Vault Helm chart 启用了 Vault Secrets Store CSI provider。先确认 Kubernetes 节点、Vault Pod 与 CSI 相关 Pod 均已就绪。

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

查看实验预生成的文件挂载清单。重点观察三处：`provider: vault`、`roleName: "csi-app"`、以及 `objects` 中的 `objectName`、`secretPath` 和 `secretKey`。

```bash
sed -n '1,140p' /root/csi-file-mount.yaml
```

最后确认 Vault 中已经有实验机密，并且 Kubernetes auth role 只绑定 `csi-demo` namespace 下名为 `app` 的 ServiceAccount。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault kv get secret/csi/app'
kubectl -n vault exec vault-0 -- /bin/sh -c 'VAULT_TOKEN=root vault read auth/kubernetes/role/csi-app'
```