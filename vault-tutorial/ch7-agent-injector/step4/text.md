# 第四步：体验 init-only Job

长期运行的服务可以保留 sidecar，但 `Job` 和 `CronJob` 通常更希望任务完成后 Pod 能干净退出。Injector 提供 `vault.hashicorp.com/agent-pre-populate-only: "true"`，表示只注入 init container，不注入运行期 sidecar。

先查看 Job YAML 中的 init-only 注解。

```bash
sed -n '1,100p' /root/init-only-job.yaml
```

运行 Job，并等待它完成。

```bash
kubectl -n demo delete job injector-init-only --ignore-not-found
kubectl -n demo apply -f /root/init-only-job.yaml
kubectl -n demo wait --for=condition=complete job/injector-init-only --timeout=120s
JOB_POD=$(kubectl -n demo get pod -l job-name=injector-init-only -o jsonpath='{.items[0].metadata.name}')
echo "$JOB_POD"
```

查看 Job 的日志。`worker` 容器启动时已经能读取 `/vault/secrets/config.txt`，说明 init container 已经在它启动前完成预填充。

```bash
kubectl -n demo logs "$JOB_POD" -c worker
```

对比这个 Job Pod 的容器列表。它应当有 `vault-agent-init`，但普通 containers 中只有 `worker`，没有运行期 `vault-agent` sidecar。

```bash
echo "init containers:"
kubectl -n demo get pod "$JOB_POD" -o json | jq -r '.spec.initContainers[].name'

echo "containers:"
kubectl -n demo get pod "$JOB_POD" -o json | jq -r '.spec.containers[].name'
```

本实验到这里完成。你已经分别观察了不带注解的 Pod、默认 init + sidecar 注入，以及 init-only Job 三种形态。