# 第一步：最小 policy + capabilities 与 `-output-policy`

文档 §1 那两句要先记住：

> Everything in Vault is path-based. Policies are deny by default.

我们先用 dev 模式默认挂的 KV v2（在 `secret/` 路径）来体会"默认拒绝"
和"刚好够用的 capabilities"。

## 1.1 写一条最小 policy

```bash
vault kv put secret/hello message="hi from vault"
```

写一条 policy 只允许读 `secret/hello`：

```bash
vault policy write read-hello - <<'EOF'
path "secret/data/hello" {
  capabilities = ["read"]
}
EOF
```

> 注意——KV v2 的实际数据路径是 `secret/data/hello`，不是
> `secret/hello`。`vault kv get secret/hello` 这种 CLI 简写底下走的
> HTTP 是 `GET /v1/secret/data/hello`，policy 必须按真实 API 路径写。

## 1.2 拿一个挂这条 policy 的 token，验证"刚好够用"

```bash
TOKEN=$(vault token create -policy=read-hello -format=json | jq -r .auth.client_token)

echo "读 secret/hello（应该成功）:"
VAULT_TOKEN=$TOKEN vault kv get secret/hello | grep message

echo "读 secret/world（应该失败 - 不在 policy 里）:"
vault kv put secret/world message="other"
VAULT_TOKEN=$TOKEN vault kv get secret/world 2>&1 | tail -3

echo "写 secret/hello（应该失败 - 没有 update capability）:"
VAULT_TOKEN=$TOKEN vault kv put secret/hello message="changed" 2>&1 | tail -3
```

三个反应分别是：成功 / 403 未授权 / 403 capability 不足。这正是"deny
by default + capabilities 精确控制"的体现。

## 1.3 不知道某个命令需要什么 capability？用 `-output-policy`

文档 §1.2 说的偷懒招——任何命令前面加 `-output-policy` 就能反推 policy：

```bash
echo "vault kv get 需要什么权限:"
vault kv get -output-policy secret/hello

echo ""
echo "vault kv put 需要什么权限:"
vault kv put -output-policy secret/hello message=test
```

注意 `kv put` 的输出里 capabilities 是 `["create", "update"]` 两个
都要——这就是文档强调的"绝大多数 Vault 路径不区分 create 和 update，
**默认就要一起写**"。

## 1.4 体验 `read` 不一定是"读"

动态机密接口从底层看是 GET → 对应 `read`，但业务语义其实是"创建一个
新账号"。我们用 KV 的 `metadata` 端点演示一下"GET 看起来像读其实在
拉一组数据"：

```bash
echo "kv metadata get 需要什么权限:"
vault kv metadata get -output-policy secret/hello
```

输出依然是 `read`——因为 HTTP verb 是 GET。**写 policy 永远以 HTTP
动词为准，不要被业务名词误导**。

**这一步的核心结论**：

| 现象 | 原因 |
| --- | --- |
| 路径不在 policy 里 → 403 | deny by default |
| 路径在 policy 里但 capability 不全 → 403 | capabilities 也是 deny by default |
| `kv put` 同时需要 `create` + `update` | 多数 Vault API 不区分这两者 |
| `kv get` 需要 `read`（哪怕底层是"生成新凭据"） | policy 跟 HTTP 动词对齐，不是业务语义 |
| 不知道写什么 capability | `-output-policy` 自动反推 |
