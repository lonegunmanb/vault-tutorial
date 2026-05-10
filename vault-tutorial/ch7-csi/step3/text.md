# 第三步：故意换错 Pod 身份，再修回正确配置

这一页先做一个故意失败的实验，再把它修好。目的不是停在报错，而是让你看到权限边界在哪里，以及正确配置到底长什么样。

第二步能成功，是因为 Pod 使用了 `csi-demo/app` 这个 ServiceAccount；Vault role `csi-app` 也正好绑定了这个身份。现在我们创建一个几乎相同的 Pod，但让它使用 `csi-demo/default` 这个默认 ServiceAccount。它仍然引用同一个 `SecretProviderClass`，但身份不匹配，所以应该挂载失败。

如果你是按顺序做完第二步再来到这里，`SecretProviderClass/vault-kv-files` 已经存在，可以直接继续。如果你刚做完第一步，想直接跳到第三步验证身份边界，也可以先只创建这个失败实验需要的 `SecretProviderClass`：

```bash
awk '/^---$/ {exit} {print}' /root/csi-file-mount.yaml | kubectl apply -f -
```

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

现在先不要删除它。查看这个失败 Deployment 当前使用的 Pod 身份。

```bash
kubectl -n csi-demo get deployment csi-bad-sa \
  -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
```

你应该会看到 `default`。这就是失败的根因：Vault role `csi-app` 只绑定了 `csi-demo/app`，没有绑定 `csi-demo/default`。

正确配置其实只差这一行：Pod template 里的 `serviceAccountName` 应该是 `app`。

```yaml
spec:
  template:
    spec:
      serviceAccountName: app
```

把同一个 Deployment 修回正确身份。Deployment 会创建一个新的 Pod；新 Pod 使用 `csi-demo/app` 身份，因此应该能通过 Vault role 约束并完成 CSI 挂载。

```bash
kubectl -n csi-demo patch deployment csi-bad-sa \
  --type='merge' \
  -p '{"spec":{"template":{"spec":{"serviceAccountName":"app"}}}}'

kubectl -n csi-demo rollout status deployment/csi-bad-sa --timeout=180s
kubectl -n csi-demo get pods -l app=csi-bad-sa -o wide
```

验证修复后的 Pod 已经能看到 Vault 挂载文件。

```bash
FIXED_POD=$(kubectl -n csi-demo get pod -l app=csi-bad-sa \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n csi-demo exec "$FIXED_POD" -- ls -l /mnt/secrets-store
kubectl -n csi-demo exec "$FIXED_POD" -- cat /mnt/secrets-store/appUsername
```

确认修复成功后，清理这个示例 Deployment，避免它留在后续步骤里。

```bash
kubectl -n csi-demo delete deployment csi-bad-sa
```

这个失败再修复的示例说明，CSI provider 使用的是发起挂载的 Pod 的 ServiceAccount 身份。只要 Vault role 没有绑定该 ServiceAccount，挂载就不会成功；把 Pod 身份改回 Vault role 允许的 `csi-demo/app` 后，同一份 `SecretProviderClass` 就能正常挂载。

这也是生产中要使用专用 ServiceAccount 的原因：不同应用绑定不同 Vault role，才能限制每个应用只能读取自己需要的 Vault 路径。