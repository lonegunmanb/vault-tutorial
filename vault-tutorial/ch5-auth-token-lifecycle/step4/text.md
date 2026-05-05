# 第四步：续期与撤销：token 值和 accessor

创建一枚可续期的短 TTL token。为了便于观察，同时保存 token 值和 accessor。

```bash
RENEW_JSON=$(vault token create -policy=default -ttl=2m -format=json)
RENEW_TOKEN=$(jq -r .auth.client_token <<< "$RENEW_JSON")
RENEW_ACCESSOR=$(jq -r .auth.accessor <<< "$RENEW_JSON")

vault token lookup "$RENEW_TOKEN" | grep -E 'ttl|renewable|accessor'
```

先用 token 值请求续期到 10 分钟。

```bash
vault token renew -increment=10m "$RENEW_TOKEN"
```

再用 accessor 请求续期。使用 accessor 时，输出不会暴露 token 值。

```bash
vault token renew -accessor -increment=10m "$RENEW_ACCESSOR"
```

用 accessor 撤销这枚 token。

```bash
vault token revoke -accessor "$RENEW_ACCESSOR"
```

撤销后再次查询应失败。

```bash
vault token lookup -accessor "$RENEW_ACCESSOR" 2>&1 | tail -3
```

这一阶段的关键点是：accessor 可以执行有限管理动作，但不能当作访问 Vault 的 token 使用。
