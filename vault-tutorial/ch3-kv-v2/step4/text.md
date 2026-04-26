# 第四步：Policy 路径踩坑——`data/` 段错配 → 403，修复后恢复

3.2 §7 反复强调过的问题：**KV v2 的 Policy 必须显式包含 `data/`、
`metadata/` 等中间段**，写成 v1 风格会神不知鬼不觉地失效。这一步
亲自踩一次。

## 4.1 准备一份测试数据 + 一个测试身份

```bash
# 重新写一条 key（前一步把 secret-x 抹掉了，挑一条新的）
vault kv put kv/app/db username=root password=alpha > /dev/null

# 启用 userpass，建一个测试用户 alice，绑定一条还没创建的 policy
vault auth enable userpass 2>/dev/null || echo "userpass 已启用"
vault write auth/userpass/users/alice \
  password=training \
  policies=kv-app-read

# 拿 alice 的 token 备用
ALICE_TOKEN=$(vault login -method=userpass \
  username=alice password=training \
  -format=json | jq -r .auth.client_token)
echo "alice token = $ALICE_TOKEN"
```

注意 alice 当前绑的 policy 名 `kv-app-read` **还没写入 Vault**，所
以现在她什么都读不到。

## 4.2 写一份"v1 风格"的错误 Policy

照着 KV v1 的直觉写，路径里**没有 `data/` 段**：

```bash
vault policy write kv-app-read - <<'EOF'
path "kv/app/*" {
  capabilities = ["read", "list"]
}
EOF

vault policy read kv-app-read
```

直观上"这条 policy 给 `kv/app/*` 加了 read"，alice 现在应该能读
`kv/app/db` 才对。试一下：

```bash
echo "=== alice 用错误 policy 读 kv/app/db（预计 403）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv get kv/app/db 2>&1 | tail -5
export VAULT_TOKEN='root'
```

果然 **`permission denied`**——因为底层 HTTP 路径其实是 `kv/data/app/db`，
而 policy 里写的是 `kv/app/db`，根本没匹配上。

## 4.3 list 也一样会失败

```bash
echo "=== alice 用错误 policy list kv/app/（预计 403）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv list kv/app/ 2>&1 | tail -5
export VAULT_TOKEN='root'
```

`vault kv list` 走的是 `kv/metadata/app/`，policy 同样没覆盖。

## 4.4 修复 Policy：补上 `data/` 和 `metadata/`

```bash
vault policy write kv-app-read - <<'EOF'
# 读 KV v2 的实际数据
path "kv/data/app/*" {
  capabilities = ["read"]
}
# list 走 metadata/，需要单独授权
path "kv/metadata/app/*" {
  capabilities = ["list", "read"]
}
EOF

vault policy read kv-app-read
```

不需要让 alice 重新登录——Vault 在每次请求时**实时**评估 policy，
新策略立刻生效。

```bash
echo "=== alice 现在读取应该成功 ==="
VAULT_TOKEN=$ALICE_TOKEN vault kv get kv/app/db 2>&1 | tail -8

echo ""
echo "=== list 现在也行 ==="
VAULT_TOKEN=$ALICE_TOKEN vault kv list kv/app/
export VAULT_TOKEN='root'
```

`password=alpha` 出现在 Data 块里——这条 policy 才是 KV v2 真正想要
的写法。

## 4.5 把"删除三态"也按动作分开授权

按 3.2 §7 的最佳实践：让 alice 能软删但不能 destroy，把"凭据物理销毁"
留给更高权限的角色。

```bash
vault policy write kv-app-read - <<'EOF'
path "kv/data/app/*"     { capabilities = ["read", "delete"] }
path "kv/metadata/app/*" { capabilities = ["list", "read"] }

# 允许软删除 + 撤销软删
# - kv/data/<path> 的 delete   覆盖 `vault kv delete <path>`（软删最新版，DELETE kv/data/...）
# - kv/delete/<path> 的 update 覆盖 `vault kv delete -versions=N <path>`（POST kv/delete/...）
path "kv/delete/app/*"   { capabilities = ["update"] }
path "kv/undelete/app/*" { capabilities = ["update"] }

# 故意不给 destroy / metadata delete
EOF
```

验证 alice 能软删但不能 destroy：

```bash
echo "=== 软删（应成功）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv delete kv/app/db
export VAULT_TOKEN='root'

echo ""
echo "=== 撤销软删（应成功）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv undelete -versions=1 kv/app/db
export VAULT_TOKEN='root'

echo ""
echo "=== 硬 destroy（应被拒绝）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv destroy -versions=1 kv/app/db 2>&1 | tail -3
export VAULT_TOKEN='root'

echo ""
echo "=== metadata delete（应被拒绝）==="
VAULT_TOKEN=$ALICE_TOKEN vault kv metadata delete kv/app/db 2>&1 | tail -3
export VAULT_TOKEN='root'
```

最后两条都返回 403——因为我们的 policy 里**完全没提及** `kv/destroy/*`
和对 `kv/metadata/*` 的 `delete` 能力。这正是 KV v2 把删除拆成多
路径的目的：让你按动作精准授权。

## 4.6 Policy 路径段速查

写 KV v2 的 Policy 时对照这张表，避免再踩"v1 风格"的坑：

| 想做的事 | 必须出现的路径段 | capability |
| --- | --- | --- |
| `vault kv put` / `kv patch` | `kv/data/<path>` | `create` / `update` / `patch` |
| `vault kv get` | `kv/data/<path>` | `read` |
| `vault kv list` | `kv/metadata/<path>` | `list` |
| `vault kv metadata get` | `kv/metadata/<path>` | `read` |
| `vault kv delete`（软删） | `kv/delete/<path>` | `update` |
| `vault kv undelete` | `kv/undelete/<path>` | `update` |
| `vault kv destroy` | `kv/destroy/<path>` | `update` |
| `vault kv metadata delete` | `kv/metadata/<path>` | `delete` |

> 一个简单的检查办法：**任何不带 `data/`、`metadata/`、`delete/`、
> `undelete/`、`destroy/` 中间段、却试图操作 KV v2 的 Policy 路径
> 都是写错了**——它在 Vault 里根本不会被命中。

---

> 接下来回到 finish 页面回顾本实验的全部要点。
