# 第四步：Policy 强制 wrapping（min/max_wrapping_ttl）

2.6 节 §3.2 提到的 `min_wrapping_ttl` / `max_wrapping_ttl`——用它可以
在 policy 层面**强制某条路径上的请求必须用 response wrapping**。

## 4.1 准备一条敏感的 KV 机密

```bash
vault kv put secret/top-secret launch-code="ALPHA-7742"
```

## 4.2 写一条强制 wrapping 的 policy

```bash
vault policy write force-wrap - <<'EOF'
# 只能读 secret/top-secret，且必须用 response wrapping
path "secret/data/top-secret" {
  capabilities      = ["read"]
  min_wrapping_ttl  = "10s"
  max_wrapping_ttl  = "300s"
}
EOF
```

`min_wrapping_ttl = "10s"` 意味着：

- **必须**附带 `-wrap-ttl`（不附带 = 相当于 TTL=0 → 低于 min → 拒绝）
- TTL **最少** 10 秒
- TTL **最多** 300 秒（5 分钟）

## 4.3 创建挂这条 policy 的 token

```bash
TOKEN=$(vault token create -policy=force-wrap -format=json | jq -r .auth.client_token)
echo "force-wrap token = $TOKEN"
```

## 4.4 不带 `-wrap-ttl` 直接读——403 拒绝

```bash
echo "不带 -wrap-ttl 直接读 secret/top-secret（应被拒）:"
VAULT_TOKEN=$TOKEN vault kv get secret/top-secret 2>&1 | tail -5
```

错误信息会包含类似 `request would not be wrapped but a wrapping TTL was
expected` 的提示——**policy 强制要求必须 wrap**。

## 4.5 TTL 低于 min——403 拒绝

```bash
echo ""
echo "wrap-ttl=5s（低于 min 10s，应被拒）:"
VAULT_TOKEN=$TOKEN vault kv get -wrap-ttl=5s secret/top-secret 2>&1 | tail -5
```

## 4.6 TTL 高于 max——403 拒绝

```bash
echo ""
echo "wrap-ttl=600s（高于 max 300s，应被拒）:"
VAULT_TOKEN=$TOKEN vault kv get -wrap-ttl=600s secret/top-secret 2>&1 | tail -5
```

## 4.7 TTL 在 [min, max] 区间内——成功

```bash
echo ""
echo "wrap-ttl=60s（在 10s~300s 区间内，应成功）:"
WRAP_RESULT=$(VAULT_TOKEN=$TOKEN vault kv get -wrap-ttl=60s -format=json secret/top-secret)
echo "$WRAP_RESULT" | jq .wrap_info.token

echo ""
echo "拆封验证:"
WRAP_TOK=$(echo "$WRAP_RESULT" | jq -r .wrap_info.token)
vault unwrap $WRAP_TOK
```

## 4.8 root token 不受 policy 限制

```bash
echo ""
echo "用 root token 不带 wrapping 直接读（应成功——root 无视 policy）:"
vault kv get secret/top-secret | grep launch-code
```

root token 拥有 root policy，**不受任何 ACL policy 约束**——包括
`min_wrapping_ttl`。这也是为什么生产环境**绝不应该保留长期 root
token** 的另一个原因。

## 4.9 验证 capabilities 和 wrapping 约束的交互

`-output-policy` 也能看到 wrapping 约束吗？

```bash
echo ""
echo "output-policy 只会告诉你 capabilities，不包含 wrapping 约束:"
vault kv get -output-policy secret/top-secret
```

注意——`-output-policy` 输出里**没有** `min_wrapping_ttl` /
`max_wrapping_ttl`。这两个约束是**策略编写者手动加的安全护栏**，
不是 API 端点自身要求的。`-output-policy` 只反推 capabilities。

**这一步的核心结论**：

| 场景 | 结果 |
| --- | --- |
| 不附带 `-wrap-ttl`（但 policy 设了 min） | 403 |
| `-wrap-ttl` 低于 `min_wrapping_ttl` | 403 |
| `-wrap-ttl` 高于 `max_wrapping_ttl` | 403 |
| `-wrap-ttl` 在 [min, max] 区间内 | 成功返回 wrapping token |
| root token | 无视一切 policy 约束 |
| `-output-policy` | 不反推 wrapping 约束 |
