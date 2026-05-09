# 第二步：比较 `true` 与 `force` 的身份边界

先用**不携带 token** 的请求访问第一个 Proxy。由于 listener 要求 `X-Vault-Request: true` 请求头，本实验使用 `curl` 显式添加该请求头；请求没有 `X-Vault-Token` 时，Proxy 会附加自己的 Auto-auth token，所以读取成功。

```bash
curl -s \
	-H "X-Vault-Request: true" \
	http://127.0.0.1:8100/v1/secret/data/proxy73/app | jq '.data.data'
```

再用低权限 token 访问同一个 Proxy。因为 `use_auto_auth_token = true` 不会覆盖请求自带 token，所以这次会使用低权限 token 转发到 Vault，并被 Vault policy 拒绝。

```bash
curl -s -i \
	-H "X-Vault-Request: true" \
	-H "X-Vault-Token: $(cat /root/no-read-token)" \
	http://127.0.0.1:8100/v1/secret/data/proxy73/app | head -20
```

停止第一个 Proxy，准备启动 `force` 模式的第二个 Proxy。

```bash
kill "$(cat /tmp/proxy-true.pid)"
```

阅读第二个配置文件。它监听 `127.0.0.1:8101`，并把 `use_auto_auth_token` 设置为 `"force"`。

```bash
sed -n '1,120p' /root/proxy-config-force.hcl
```

启动第二个 Proxy。

```bash
nohup vault proxy -config=/root/proxy-config-force.hcl > /tmp/proxy-force.log 2>&1 &
cat /tmp/proxy-force.pid
tail -40 /tmp/proxy-force.log
```

现在继续携带同一枚低权限 token 访问目标机密。由于 `force` 模式会忽略请求自带 token，并强制使用 Proxy 的 Auto-auth token，这次读取应当成功。

```bash
curl -s \
	-H "X-Vault-Request: true" \
	-H "X-Vault-Token: $(cat /root/no-read-token)" \
	http://127.0.0.1:8101/v1/secret/data/proxy73/app | jq '.data.data'
```

这一阶段的关键点是：`true` 模式允许请求自带 token 改变最终身份；`force` 模式把最终身份固定为 Proxy Auto-auth token。因此，`force` 模式必须配合“一应用一 Proxy”和最小权限 policy 使用。