# 第二步：路径匹配优先级与 `deny` 一票否决

文档 §3 关于多条规则匹配的核心论断：

> The policy rules that Vault applies are determined by the most-specific
> match available. ... If different patterns appear in the applicable
> policies, we take only the highest-priority match from those policies.

也就是说——同一个路径被多条规则匹中时，**只有最具体的一条胜出**，
不是简单取并集。我们来验证。

## 2.1 准备数据

```bash
vault kv put secret/general note="everyone can read"
vault kv put secret/admin/payroll salary="200k"
vault kv put secret/admin/topsecret password="zzz"
```

最终要搭起来的格局：

```
   ┌─ secret/general          ← 全员可读
   ├─ secret/admin/payroll    ← 只 admin 可读
   └─ secret/admin/topsecret  ← 任何人都不能读 (deny)
```

## 2.2 写两条 policy，演示"具体路径胜出"

第一条——全员通用：

```bash
vault policy write all-read - <<'EOF'
# 通配读：secret/* 任何子路径
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
```

第二条——只给 admin 子树更宽的权限，并显式 deny 一条特殊路径：

```bash
vault policy write admin-extra - <<'EOF'
# admin 子树读 + 写
path "secret/data/admin/*" {
  capabilities = ["read", "create", "update"]
}
# 但 topsecret 任何人都不能碰，包括 admin
path "secret/data/admin/topsecret" {
  capabilities = ["deny"]
}
EOF
```

```
  policy: all-read              policy: admin-extra
  ────────────                 ─────────────────────
  secret/data/*                secret/data/admin/*       ← 更具体，胜出
    [read]                       [read,create,update]
                                 secret/data/admin/topsecret  ← 最具体
                                   [deny]
```

## 2.3 让一个 token 同时挂这两条 policy，验证优先级

```bash
TOKEN=$(vault token create -policy=all-read -policy=admin-extra -format=json | jq -r .auth.client_token)

echo "读 secret/general（命中 secret/data/* → read OK）:"
VAULT_TOKEN=$TOKEN vault kv get secret/general | grep note

echo ""
echo "读 secret/admin/payroll（命中 secret/data/admin/* → read OK）:"
VAULT_TOKEN=$TOKEN vault kv get secret/admin/payroll | grep salary

echo ""
echo "写 secret/admin/payroll（命中 secret/data/admin/* → create+update OK）:"
VAULT_TOKEN=$TOKEN vault kv put secret/admin/payroll salary="250k" | tail -3

echo ""
echo "尝试写 secret/general（命中 secret/data/* → 只有 read，没有 update）:"
VAULT_TOKEN=$TOKEN vault kv put secret/general note="hacked" 2>&1 | tail -3
```

最后那个 `secret/general` 的写**应该失败**——尽管 `secret/data/*`
看起来包了 `secret/data/general`，但匹中的只是 `[read]`。

> **关键观察**：`admin-extra` 上的 `[read,create,update]` **不会泄露
> 到 `secret/general`**，因为 `secret/data/admin/*` 这条规则路径上根
> 本不匹配 `secret/data/general`。优先级判断**只在已匹中的规则之间
> 进行**。

## 2.4 验证 `deny` 一票否决

```bash
echo "尝试读 secret/admin/topsecret（命中 deny → 必失败）:"
VAULT_TOKEN=$TOKEN vault kv get secret/admin/topsecret 2>&1 | tail -3
```

403——尽管 `secret/data/admin/*` 给了 read，但 `secret/data/admin/topsecret`
作为**更具体匹配**且 capability 是 `deny`，直接拒绝。

文档 §2.2 原话："`deny` always takes precedence regardless of any
other defined capabilities, including `sudo`."

## 2.5 反过来——把 deny 写在通配上能不能压住具体 allow？

新写一条 policy 试试：

```bash
vault policy write deny-broad - <<'EOF'
path "secret/data/admin/*" {
  capabilities = ["deny"]
}
path "secret/data/admin/payroll" {
  capabilities = ["read"]
}
EOF
```

```bash
TOKEN2=$(vault token create -policy=deny-broad -format=json | jq -r .auth.client_token)

echo "读 secret/admin/payroll（更具体匹中 [read]，应该成功）:"
VAULT_TOKEN=$TOKEN2 vault kv get secret/admin/payroll | grep salary

echo ""
echo "读 secret/admin/anything（命中通配 deny → 必失败）:"
VAULT_TOKEN=$TOKEN2 vault kv get secret/admin/topsecret 2>&1 | tail -3
```

注意——**deny 也要"赢得最具体匹配"才能生效**。如果 deny 写在通配上、
allow 写在具体路径上，**具体的 allow 反而胜出**。这跟很多人脑补的
"deny 永远赢"不一样——deny 的"一票否决"是说**在它胜出的那次匹配
里**它必赢，而不是在所有 policy 里全局压制。

**这一步的核心结论**：

| 现象 | 规则 |
| --- | --- |
| `secret/data/admin/*` vs `secret/data/*` 都匹中 `secret/data/admin/x` | 前者更具体，胜出，后者完全不参与 |
| 同一最具体匹配里 deny + allow 同时存在 | deny 一票否决 |
| 通配 deny + 具体 allow | 具体 allow 胜出（"具体性"先于"deny"） |
| 给同一具体 path 加多条 allow | 取 capabilities 并集 |
