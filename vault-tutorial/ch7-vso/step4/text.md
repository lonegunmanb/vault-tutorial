# 第四步：用 rolloutRestartTargets 触发 Deployment 滚动

查看新的 `VaultStaticSecret` 清单。与第三步相比，它增加了 `rolloutRestartTargets`，列出一个目标：`Deployment/vso-app`。

```bash
diff -u /root/vso-static-secret.yaml /root/vso-static-secret-rollout.yaml
```

应用更新后的清单。同名 `VaultStaticSecret` 会被原地更新，无需删除重建。

```bash
kubectl apply -f /root/vso-static-secret-rollout.yaml
kubectl -n vso-demo describe vaultstaticsecret vso-app-static | tail -20
```

记录当前 Deployment 的 `pod-template-hash`，用作稍后比对滚动是否发生的基线。

```bash
kubectl -n vso-demo get rs -l app=vso-app \
  -o custom-columns=NAME:.metadata.name,PODHASH:.metadata.labels.pod-template-hash,READY:.status.readyReplicas
```

再次更新 Vault 中的 KV，把密码改成下一个值。

```bash
kubectl -n vault exec vault-0 -- /bin/sh -c \
  'VAULT_TOKEN=root vault kv put secret/vso/app username=vso-user password=rotated-password-2'
```

等待 VSO 检测到变化、刷新 Kubernetes Secret 并 patch Deployment 的 pod template annotations。整个动作通常在 30 秒内完成。

```bash
sleep 30
kubectl -n vso-demo get deployment vso-app \
  -o jsonpath='{.spec.template.metadata.annotations}' | jq
```

应该可以看到一个名为 `vso.secrets.hashicorp.com/restartedAt` 的 annotation，其值是触发滚动时的时间戳。Kubernetes 会因为 pod template 变化创建新的 ReplicaSet，并按 Deployment 的更新策略滚动 Pod。

```bash
kubectl -n vso-demo get rs -l app=vso-app \
  -o custom-columns=NAME:.metadata.name,PODHASH:.metadata.labels.pod-template-hash,READY:.status.readyReplicas
kubectl -n vso-demo rollout status deployment/vso-app --timeout=120s
```

进入新的 Pod 验证 `APP_PASSWORD` 已经被替换。

```bash
NEW_POD=$(kubectl -n vso-demo get pod -l app=vso-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n vso-demo exec "$NEW_POD" -- env | grep '^APP_'
```

至此，"Vault KV 变化 → Kubernetes Secret 刷新 → Deployment 自动滚动" 这条 VSO 声明式链路就完整跑通了。
