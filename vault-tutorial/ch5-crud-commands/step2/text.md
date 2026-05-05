# 第二步：写入数据：key=value、文件、stdin 与 -force

`write` 最常见的输入形式是 `key=value`。先把一组凭据写入当前 token 的 Cubbyhole：

```bash
vault write cubbyhole/git-credentials username="student01" password='p@$$w0rd'
vault read cubbyhole/git-credentials
```

如果值很长，可以从文件读取。下面把一份小策略文件作为字符串写入 Cubbyhole：

```bash
cat > policy.json <<'EOF'
path "secret/data/app/*" {
  capabilities = ["read"]
}
EOF

vault write cubbyhole/policy-copy policy=@policy.json
vault read cubbyhole/policy-copy
```

如果值来自另一个命令，可以让某个字段从 stdin 读取：

```bash
printf 'value-from-stdin' | vault write cubbyhole/stdin-demo token=-
vault read cubbyhole/stdin-demo
```

更复杂的 API 请求可以把 `-` 作为唯一数据参数，让 `write` 从 stdin 读取完整 JSON：

```bash
cat > token-request.json <<'EOF'
{
  "policies": ["default"],
  "ttl": "30m",
  "num_uses": 1
}
EOF

cat token-request.json | vault write -format=json auth/token/create - | jq '.auth | {client_token, policies, lease_duration}'
```

最后看一个不需要请求体的写入动作：创建 Transit key。这里必须使用 `-force`，否则 `write` 会认为你忘了提供输入数据。

```bash
vault write -force transit/keys/crud-demo
vault read transit/keys/crud-demo | grep -E 'name|type|deletion_allowed'
```

这一轮练习的重点不是记住这些具体路径，而是熟悉四种输入方式：`key=value`、`@file`、`key=-`、单独的 `-` JSON 请求体。
