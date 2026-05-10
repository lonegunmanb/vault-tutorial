# 第四步：先同步成 Kubernetes Secret，再注入环境变量

这一页演示第二种消费方式：应用不读 `/mnt/secrets-store` 文件，而是读环境变量。

注意这里多了一次“中转”：Vault 数据先被 CSI driver/provider 同步成 Kubernetes Secret `vault-csi-app-env`，然后另一个应用 Pod 再用 Kubernetes 原生的 `secretKeyRef` 把这个 Secret 注入成环境变量。也就是说，环境变量不是 Vault provider 直接塞进容器的，而是 Kubernetes 从自己的 Secret 对象里注入的。

先查看带 `secretObjects` 的 `SecretProviderClass` 清单。`secretObjects.data[].objectName` 引用 `objects` 中的对象别名，`key` 则成为 Kubernetes Secret 中的键名。

```bash
sed -n '1,130p' /root/csi-env-sync.yaml
```

应用同步清单。这个 Deployment 会挂载 CSI volume，从而触发 provider 读取 Vault 数据并创建名为 `vault-csi-app-env` 的 Kubernetes Secret。

这里的 `csi-env-syncer` 像一个触发器：它挂载 CSI volume，所以同步动作会发生。没有 Pod 引用 `SecretProviderClass` 时，只创建 `SecretProviderClass` 并不会立刻生成 Kubernetes Secret。

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

这个 `csi-env-app` 不需要再挂载 CSI volume；它只是普通 Kubernetes 应用，读取的是 `vault-csi-app-env` 这个 Kubernetes Secret。

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

到这里你已经对比了两条路径：第二步是 Vault 数据直接变成 Pod 里的文件；第四步是 Vault 数据先变成 Kubernetes Secret，再变成环境变量。第三步夹在中间，是为了证明这两条路径都受 Pod ServiceAccount 与 Vault role 的绑定约束。