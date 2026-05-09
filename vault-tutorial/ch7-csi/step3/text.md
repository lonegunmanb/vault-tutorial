# 第三步：验证 ServiceAccount 权限边界

Vault role `csi-app` 只允许 `csi-demo` namespace 中名为 `app` 的 ServiceAccount 登录。现在创建一个几乎相同的 Pod，但让它使用默认 ServiceAccount。

```bash
kubectl apply -f /root/csi-bad-sa.yaml
```

这个 Pod 预期不会进入正常 Running 状态，因为它在 `ContainerCreation` 阶段无法用默认 ServiceAccount 通过 Vault role 约束。先观察 Pod 状态。

```bash
kubectl -n csi-demo get pods -l app=csi-bad-sa
```

查看事件。不同版本的 CSI driver 和 provider 日志文字可能略有差异，但应能看到 volume mount、permission denied、forbidden 或 Vault 登录失败一类信息。

```bash
BAD_POD=$(kubectl -n csi-demo get pod -l app=csi-bad-sa -o jsonpath='{.items[0].metadata.name}')
kubectl -n csi-demo describe pod "$BAD_POD" | sed -n '/Events:/,$p'
```

如果事件还没有出现，稍等几秒再查看一次。

```bash
for i in $(seq 1 10); do
  kubectl -n csi-demo describe pod "$BAD_POD" | grep -Ei 'mount|permission|denied|forbidden|vault' && break
  echo "waiting for mount failure event..."
  sleep 3
done
```

清理失败示例，避免它持续重试。

```bash
kubectl -n csi-demo delete deployment csi-bad-sa
```

这个失败示例说明，CSI provider 使用的是发起挂载的 Pod 的 ServiceAccount 身份。只要 Vault role 没有绑定该 ServiceAccount，挂载就不会成功。