# 第二步：用 annotation 触发注入

查看即将部署的带注解 Deployment。注意注解写在 `spec.template.metadata.annotations` 下，而不是写在 Deployment 顶层 metadata 下。

```bash
sed -n '1,80p' /root/injector-demo.yaml
```

应用 Deployment，并等待新的 Pod 就绪。

```bash
kubectl -n demo apply -f /root/injector-demo.yaml
kubectl -n demo rollout status deployment/injector-demo
INJECTED_POD=$(kubectl -n demo get pod -l app=injector-demo -o jsonpath='{.items[0].metadata.name}')
echo "$INJECTED_POD"
```

Injector 成功改写后，会给 Pod 增加 `vault.hashicorp.com/agent-inject-status: injected` 注解，用来阻止重复 mutation。

```bash
kubectl -n demo get pod "$INJECTED_POD" -o json \
  | jq -r '.metadata.annotations["vault.hashicorp.com/agent-inject-status"]'
```

现在观察 Pod spec 中多出的 init container、sidecar container 与 memory volume。

```bash
echo "init containers:"
kubectl -n demo get pod "$INJECTED_POD" -o json | jq -r '.spec.initContainers[].name'

echo "containers:"
kubectl -n demo get pod "$INJECTED_POD" -o json | jq -r '.spec.containers[].name'

echo "memory volumes:"
kubectl -n demo get pod "$INJECTED_POD" -o json \
  | jq -r '.spec.volumes[] | select(.emptyDir.medium == "Memory") | .name'
```

你应该能看到 `vault-agent-init`、业务容器 `app`、运行期 `vault-agent`，以及用于共享机密文件的内存卷。