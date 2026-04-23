# 第二步：Token 树与级联撤销

文档 §3.1 的核心论断：

> When a parent token is revoked, all of its child tokens — and all of
> their leases — are revoked as well.

我们手工搭一棵 3 层 token 树，然后撤中间节点看会发生什么。

确保在 root 身份：

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
```

## 2.1 构造 3 层 token 树

先写一条允许创建子 token 的 policy（`default` policy 不包含
`auth/token/create` 权限，直接用会 403）：

```bash
vault policy write token-admin - <<'EOF'
path "auth/token/create" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke" {
  capabilities = ["update"]
}
EOF
```

```bash
# 第 1 层：从 root 派生 ops 节点，附带 token-admin policy
OPS=$(vault token create -policy=default -policy=token-admin -ttl=1h -format=json | jq -r .auth.client_token)
echo "OPS=$OPS"

# 第 2 层：以 OPS 身份派生两个 mid 节点
MID_A=$(VAULT_TOKEN=$OPS vault token create -ttl=30m -format=json | jq -r .auth.client_token)
MID_B=$(VAULT_TOKEN=$OPS vault token create -ttl=30m -format=json | jq -r .auth.client_token)

# 第 3 层：以 MID_A 身份派生两个叶子
LEAF_1=$(VAULT_TOKEN=$MID_A vault token create -ttl=10m -format=json | jq -r .auth.client_token)
LEAF_2=$(VAULT_TOKEN=$MID_A vault token create -ttl=10m -format=json | jq -r .auth.client_token)

echo "构造完毕："
echo "  root"
echo "    └── OPS"
echo "          ├── MID_A"
echo "          │     ├── LEAF_1"
echo "          │     └── LEAF_2"
echo "          └── MID_B"
```

逐个 lookup 看一眼，注意 `display_name` 都是 `token`（自己派生的，
不是从 auth method 来）、并且**都不是 orphan**：

```bash
for t in "$OPS" "$MID_A" "$MID_B" "$LEAF_1" "$LEAF_2"; do
  vault token lookup "$t" | grep -E "display_name|orphan"
  echo "---"
done
```

## 2.2 撤掉中间节点 MID_A，看 LEAF 全死

```bash
vault token revoke "$MID_A"
```

立刻验证 4 个相关 token 的状态：

```bash
echo "MID_A:"
vault token lookup "$MID_A" 2>&1 | tail -3

echo "LEAF_1:"
vault token lookup "$LEAF_1" 2>&1 | tail -3

echo "LEAF_2:"
vault token lookup "$LEAF_2" 2>&1 | tail -3

echo "MID_B（未受影响）:"
vault token lookup "$MID_B" 2>&1 | grep ttl
```

`MID_A` / `LEAF_1` / `LEAF_2` 应该都报 `bad token` —— **MID_A 整棵子树
被一句话连根拔起**；`MID_B` 在另一棵分支上，毫发无损。

这就是 2.3 章节"撤父 token 级联撤所有子租约"的本质——级联是沿着 token
**树**走的，不是沿着 lease 走的。

## 2.3 用 revoke-orphan 做"外科手术"

文档 §3.4 那个危险但有用的命令——撤掉中间节点，但**让它的直接子节点
升格为 orphan**，孙子节点不受影响。

重新搭一棵：

```bash
OPS2=$(vault token create -policy=default -policy=token-admin -ttl=1h -format=json | jq -r .auth.client_token)
MID2=$(VAULT_TOKEN=$OPS2 vault token create -ttl=30m -format=json | jq -r .auth.client_token)
LEAF2_1=$(VAULT_TOKEN=$MID2 vault token create -ttl=10m -format=json | jq -r .auth.client_token)
LEAF2_2=$(VAULT_TOKEN=$MID2 vault token create -ttl=10m -format=json | jq -r .auth.client_token)
```

确认现在 `LEAF2_1` 不是 orphan：

```bash
vault token lookup "$LEAF2_1" | grep orphan
# orphan    false
```

对中间节点 `MID2` 用 `revoke-orphan`：

```bash
vault write -force auth/token/revoke-orphan token="$MID2"
```

再看：

```bash
echo "MID2 (应该已死):"
vault token lookup "$MID2" 2>&1 | tail -2

echo "LEAF2_1 (应该升格为 orphan):"
vault token lookup "$LEAF2_1" | grep -E "orphan|ttl"

echo "LEAF2_2 (应该升格为 orphan):"
vault token lookup "$LEAF2_2" | grep -E "orphan|ttl"
```

`MID2` 死了，但 `LEAF2_1` / `LEAF2_2` 还活着，并且 `orphan true`——
它们各自成了一棵新树的根。**这一招的实战意义**：当你需要紧急吊销
某个中间层（例如某个 dept-level service account 被怀疑泄漏），但又
不想把它管的几百个下游子 token 全部殃及导致业务停摆，就用这个。

文档原话："Use with caution!" —— orphan 之后这些 token 就不再受任何
集中撤销保护，必须人工额外管理。
