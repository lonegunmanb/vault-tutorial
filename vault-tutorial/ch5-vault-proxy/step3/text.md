# 第三步：通过 Proxy 代理 Vault API 请求

先故意不带 `X-Vault-Request` 请求头访问 Proxy listener。

```bash
curl -s -i http://127.0.0.1:8100/v1/secret/data/proxy/app | head -8
```

你应看到 `412 Precondition Failed`。这是 Proxy listener 的请求头保护，不是 Vault policy 拒绝。

加上 `X-Vault-Request: true` 后再次请求。注意这里没有提供 `X-Vault-Token`，但 Proxy 会使用 Auto-auth token 转发请求。

```bash
curl -s \
  -H "X-Vault-Request: true" \
  http://127.0.0.1:8100/v1/secret/data/proxy/app | jq
```

观察返回的用户名和密码字段。

```bash
curl -s \
  -H "X-Vault-Request: true" \
  http://127.0.0.1:8100/v1/secret/data/proxy/app \
  | jq -r '.data.data | "username=\(.username), password=\(.password)"'
```

现在故意在请求里带上 root token，并通过 `auth/token/lookup-self` 查看最终被 Vault 识别的 token。由于配置使用 `use_auto_auth_token = "force"`，Proxy 会忽略请求自带 token，改用 Auto-auth token。

```bash
curl -s \
  -H "X-Vault-Request: true" \
  -H "X-Vault-Token: root" \
  http://127.0.0.1:8100/v1/auth/token/lookup-self \
  | jq '.data.policies'
```

输出中应包含 `proxy-app-read`，不应表现为 root 身份。最后尝试访问 Proxy token 没有权限的系统路径。

```bash
curl -s -i \
  -H "X-Vault-Request: true" \
  http://127.0.0.1:8100/v1/sys/mounts | head -12
```

这一次应是 Vault 返回的权限错误。请把它与前面的 412 区分开：412 是 Proxy listener 的请求头保护，403 是 Vault 对最终 token 的权限判定。
