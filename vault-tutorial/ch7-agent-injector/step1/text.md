# 第一步：检查 Injector 与基线 Pod

先确认 Vault Helm chart 已经部署出 Vault Agent Injector。Injector 是一个运行在 Kubernetes 集群中的 webhook controller，后续 Pod 创建请求会先经过它判断是否需要注入。

```bash
kubectl -n vault get pods
kubectl -n vault get deployment vault-agent-injector
kubectl get mutatingwebhookconfigurations | grep vault
```

确认 Vault 中已经存在本实验的 Kubernetes auth role 与 KV v2 机密。

```bash
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