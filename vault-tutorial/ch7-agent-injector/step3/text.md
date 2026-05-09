# 第三步：读取 `/vault/secrets` 并观察刷新

进入业务容器，查看 Injector 渲染出的机密文件。业务容器只读取本地文件，并不知道 Vault 登录 API 或 TokenReview 细节。

```bash
kubectl -n demo exec "$INJECTED_POD" -c app -- ls -l /vault/secrets
kubectl -n demo exec "$INJECTED_POD" -c app -- cat /vault/secrets/config.txt
```

`config.txt` 文件来自这两个配对注解：

```bash
grep -n 'agent-inject-secret-config.txt\|agent-inject-template-config.txt' /root/injector-demo.yaml
```

现在更新 Vault 中的 KV v2 机密。本实验把 `template-static-secret-render-interval` 设为 `10s`，便于观察 sidecar 在运行期重新渲染静态机密。

```bash
vault kv put secret/injector/web username="injector-demo" password="rotated-password"
```

循环观察文件内容，直到看到新密码。真实生产环境不应随意把静态机密刷新间隔调得过短；这里是为了让实验在有限时间内可见。

```bash
for i in $(seq 1 12); do
  echo "attempt $i"
  kubectl -n demo exec "$INJECTED_POD" -c app -- cat /vault/secrets/config.txt
  kubectl -n demo exec "$INJECTED_POD" -c app -- grep -q rotated-password /vault/secrets/config.txt && break
  sleep 2
done
```

完成这一步后，你已经验证了 sidecar container 的核心价值：Pod 启动后，它仍然可以继续认证并把机密渲染到共享 volume。