# 第三步：故意换错 Pod 身份，观察挂载失败

这一页是一个故意失败的实验。目的不是让应用跑起来，而是让你看到权限边界在哪里。

上一页能成功，是因为 Pod 使用了 `csi-demo/app` 这个 ServiceAccount；Vault role `csi-app` 也正好绑定了这个身份。现在我们创建一个几乎相同的 Pod，但让它使用 `csi-demo/default` 这个默认 ServiceAccount。它仍然引用同一个 `SecretProviderClass`，但身份不匹配，所以应该挂载失败。

```bash
kubectl apply -f /root/csi-bad-sa.yaml
```

这个 Pod 预期不会进入正常 Running 状态，因为它在 `ContainerCreation` 阶段无法用默认 ServiceAccount 通过 Vault role 约束。先观察 Pod 状态。

如果你看到 `ContainerCreating`、`CreateContainerConfigError` 或类似状态，不要急着修它；这一步就是要观察失败。

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

这也是生产中要使用专用 ServiceAccount 的原因：不同应用绑定不同 Vault role，才能限制每个应用只能读取自己需要的 Vault 路径。