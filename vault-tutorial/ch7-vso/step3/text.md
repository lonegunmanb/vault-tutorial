# 第三步：用 VaultStaticSecret 同步 KV 并消费

查看 `VaultStaticSecret` 清单。它声明从 KV v2 引擎挂载点 `secret`、路径 `vso/app` 读取数据，每 15 秒刷新一次，并把结果写入名为 `vso-app-secret` 的 Kubernetes Secret（`destination.create: true` 意味着该 Secret 由 VSO 自动创建）。

```bash
cat /root/vso-static-secret.yaml
```

应用清单，并等待 VSO 完成首次同步。

```bash
kubectl apply -f /root/vso-static-secret.yaml
sleep 5
kubectl -n vso-demo get vaultstaticsecret
kubectl -n vso-demo get secret vso-app-secret -o yaml | head -30
```

确认 Kubernetes Secret 中的 `username` / `password` 字段就是 Vault 中的初始值。

```bash
kubectl -n vso-demo get secret vso-app-secret \
  -o jsonpath='{.data.username}' | base64 -d && echo
kubectl -n vso-demo get secret vso-app-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

部署一个消费 Pod。它通过 `envFrom` 把 `vso-app-secret` 中所有键注入为环境变量，并额外用 `secretKeyRef` 把 `username` / `password` 显式映射为 `APP_USERNAME` / `APP_PASSWORD`。

```bash
kubectl apply -f /root/vso-app-deployment.yaml
kubectl -n vso-demo rollout status deployment/vso-app --timeout=180s
APP_POD=$(kubectl -n vso-demo get pod -l app=vso-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n vso-demo exec "$APP_POD" -- env | grep -E '^(APP_|username|password)'
```

现在更新 Vault 中的 KV，把密码改成新值。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c \
  'VAULT_TOKEN=root vault kv put secret/vso/app username=vso-user password=rotated-password-1'
```

等待一个 `refreshAfter` 周期（约 15-30 秒）后再查看 Kubernetes Secret，可以观察到 `password` 字段已经被刷新；但**消费 Pod 的环境变量并不会自动变化**——这是 Kubernetes 环境变量注入的固有行为，需要 Pod 重启才能读取新的值。

```bash
sleep 25
kubectl -n vso-demo get secret vso-app-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

APP_POD=$(kubectl -n vso-demo get pod -l app=vso-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n vso-demo exec "$APP_POD" -- env | grep '^APP_PASSWORD'
```

下一步将通过 `rolloutRestartTargets` 让 VSO 在 Secret 变化时自动触发 Deployment 重启。
