# 第二步：把 Vault 机密挂成 Pod 里的文件

这一页开始真正“消费机密”。你会创建两个对象：

- `SecretProviderClass/vault-kv-files`：取密配置单，说明从 Vault 的 `secret/data/csi/app` 里取 `username` 和 `password`。
- `Deployment/csi-file-app`：一个 BusyBox 应用 Pod，它把 CSI volume 挂到 `/mnt/secrets-store`。

当 Pod 被创建时，CSI driver 会发现它引用了 `vault-kv-files`，于是调用 Vault provider。Vault provider 使用这个 Pod 的 ServiceAccount token 登录 Vault role `csi-app`，读取 Vault 里的字段，最后把值写成 `/mnt/secrets-store/appUsername` 和 `/mnt/secrets-store/appPassword` 两个文件。

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

看到这两个文件，就说明整条链路已经跑通：Pod 身份校验成功，Vault 数据读取成功，CSI volume 写入成功。这里打印的是教学用假数据；真实环境不要把机密直接输出到共享终端或日志里。

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

换句话说，应用只知道“本地有两个文件”；至于怎么登录 Vault、怎么从 Vault 取值，是 CSI driver 与 Vault provider 帮它完成的。