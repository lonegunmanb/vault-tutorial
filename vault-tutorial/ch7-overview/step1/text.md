# 第一步：方式一 —— `vault kv get` 直接读取

先确认 Vault 已经可用，并查看本实验预置的 KV 机密。

```bash
vault status
vault kv get secret/seven/app
```

观察 `vault kv get` 是如何认证的。它使用了你当前 shell 中的 `VAULT_TOKEN` 环境变量；在 dev 模式下，这个值是 `root`，权限非常大。

```bash
echo "VAULT_TOKEN=$VAULT_TOKEN"
vault token lookup | grep -E 'display_name|policies|ttl'
```

记录下方式一的关键事实：

- **认证主体**：当前 shell 的 `VAULT_TOKEN` 环境变量（本实验中为 root token）。
- **令牌存放位置**：环境变量。
- **机密呈现形式**：CLI 标准输出，由调用方自己决定如何使用。
- **缓存归属**：无；每次 `vault kv get` 都会向 Vault 发起一次新的 HTTP 读请求。

这是最直接的接入方式，但也意味着应用必须自己负责管理认证、续期和读机密的全部步骤。后续两步将逐步把这些职责交给 Agent 与 Proxy。
