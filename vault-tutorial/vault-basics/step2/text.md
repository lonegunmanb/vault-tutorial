# 第二步：写入和读取密钥

KV（Key-Value）Secrets Engine 是 Vault 最基础的密钥存储方式。

> **提示**：Vault Dev 模式启动时已自动挂载 `secret/`（KV v2），无需手动启用。
> 如果需要在其他路径挂载，可以使用：`vault secrets enable -path=mypath kv-v2`

写入一个密钥：

```bash
vault kv put secret/myapp/config \
  username="admin" \
  password="s3cr3t"
```

读取密钥：

```bash
vault kv get secret/myapp/config
```

以 JSON 格式读取：

```bash
vault kv get -format=json secret/myapp/config
```

只获取某个字段的值：

```bash
vault kv get -field=password secret/myapp/config
```
