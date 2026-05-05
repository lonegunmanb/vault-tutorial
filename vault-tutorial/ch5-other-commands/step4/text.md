# 第四步：`unwrap` 一次性取出封装响应

本步骤会读取一份 KV v2 数据，但不直接返回真实内容，而是让 Vault 返回 response wrapping token。随后用 `vault unwrap` 取出被封装的响应。

先确认原始数据存在：

```bash
vault kv get -mount=secret training/wrapped
```

用通用 `read` 命令读取同一份数据，并要求 Vault 封装响应：

```bash
WRAP_JSON=$(vault read -wrap-ttl=2m -format=json secret/data/training/wrapped)
echo "$WRAP_JSON" | jq '{wrap_info}'
```

提取 wrapping token：

```bash
WRAP_TOKEN=$(jq -r .wrap_info.token <<< "$WRAP_JSON")
echo "$WRAP_TOKEN"
```

使用 token 参数解封装：

```bash
vault unwrap "$WRAP_TOKEN"
```

同一枚 wrapping token 已经被使用后，可以再次尝试解封装，观察 Vault 返回的结果：

```bash
vault unwrap "$WRAP_TOKEN" 2>&1 | tail -3
```

再生成一枚 wrapping token，并把它作为当前请求 token 来解封装：

```bash
WRAP_TOKEN2=$(vault read -wrap-ttl=2m -format=json secret/data/training/wrapped | jq -r .wrap_info.token)
VAULT_TOKEN="$WRAP_TOKEN2" vault unwrap
```

这一阶段的关键点是：`unwrap` 取出的内容与直接读取原路径的响应一致；wrapping token 是用来交接封装响应的凭据，不应被当作长期访问凭据保存。