# 第四步：同步 Kubernetes Secret 并注入环境变量

先查看带 `secretObjects` 的 `SecretProviderClass` 清单。`secretObjects.data[].objectName` 引用 `objects` 中的对象别名，`key` 则成为 Kubernetes Secret 中的键名。

```bash
sed -n '1,130p' /root/csi-env-sync.yaml
```

应用同步清单。这个 Deployment 会挂载 CSI volume，从而触发 provider 读取 Vault 数据并创建名为 `vault-csi-app-env` 的 Kubernetes Secret。

```bash
kubectl apply -f /root/csi-env-sync.yaml
kubectl -n csi-demo rollout status deployment/csi-env-syncer --timeout=180s
```

确认同步出来的 Kubernetes Secret，并解码其中两个键。这里看到的是 Kubernetes Secret 中的数据，不再是直接从 `/mnt/secrets-store` 读取文件。

```bash
kubectl -n csi-demo get secret vault-csi-app-env -o yaml
kubectl -n csi-demo get secret vault-csi-app-env -o jsonpath='{.data.username}' | base64 -d && echo
kubectl -n csi-demo get secret vault-csi-app-env -o jsonpath='{.data.password}' | base64 -d && echo
```

现在创建一个只通过 `secretKeyRef` 读取环境变量的应用 Pod。它使用的值来自刚刚同步出的 Kubernetes Secret。

```bash
kubectl apply -f /root/csi-env-app.yaml
kubectl -n csi-demo rollout status deployment/csi-env-app --timeout=180s
```

查看应用日志或进入容器读取环境变量，确认 `APP_USERNAME` 与 `APP_PASSWORD` 已经被注入。

```bash
ENV_POD=$(kubectl -n csi-demo get pod -l app=csi-env-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n csi-demo logs "$ENV_POD"
kubectl -n csi-demo exec "$ENV_POD" -- env | grep '^APP_'
```

本步骤展示的是“先同步为 Kubernetes Secret，再由 Kubernetes 注入环境变量”的路径。与文件挂载相比，它更贴近传统应用读取环境变量的方式，但也意味着机密被物化为 Kubernetes Secret，需要额外考虑 RBAC、etcd 加密与审计策略。