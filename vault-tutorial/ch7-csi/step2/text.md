# 第二步：用 SecretProviderClass 挂载文件

应用文件挂载清单。`csi-demo` namespace 与 `app` ServiceAccount 已经在第一步创建；这个清单会创建 `vault-kv-files` 这个 `SecretProviderClass`，以及一个挂载 CSI volume 的 Deployment。

```bash
kubectl apply -f /root/csi-file-mount.yaml
```

等待 Deployment 就绪。Pod 创建时，Secrets Store CSI driver 会在容器启动前调用 Vault provider 读取机密并写入 `/mnt/secrets-store`。

```bash
kubectl -n csi-demo rollout status deployment/csi-file-app --timeout=180s
kubectl -n csi-demo get pods -l app=csi-file-app -o wide
```

进入容器查看挂载目录。`objectName` 决定文件名，因此你会看到 `appUsername` 与 `appPassword` 两个文件。

```bash
POD=$(kubectl -n csi-demo get pod -l app=csi-file-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n csi-demo exec "$POD" -- ls -l /mnt/secrets-store
kubectl -n csi-demo exec "$POD" -- cat /mnt/secrets-store/appUsername
kubectl -n csi-demo exec "$POD" -- cat /mnt/secrets-store/appPassword
```

再查看 Pod 的 volume 配置，确认它引用的是 `secrets-store.csi.k8s.io` driver 和 `vault-kv-files` 这个 `SecretProviderClass`。

```bash
kubectl -n csi-demo get pod "$POD" -o jsonpath='{.spec.volumes[0].csi}' | jq
```

这一步完成后，应用看到的是普通文件。应用本身没有调用 Vault API，也没有直接读取 Kubernetes ServiceAccount token。