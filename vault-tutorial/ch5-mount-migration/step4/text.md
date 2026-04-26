# 第四步：Policy 路径更新与生产注意事项

Mount Migration 有一个非常重要的 **"不做"** 的事情——**它不会自动修改 Policy 里的路径**。这是设计上的有意选择：Policy 属于独立的管理域，Vault 不假设你希望所有引用旧路径的 Policy 都自动跟着变。

## 4.1 创建一条引用旧路径的 Policy，观察路径迁移后它怎么断裂

环境初始化时在创建 `alice` 这个用户时绑定了 policy `app-team-a-read`，
但这个 policy 本身还没被写进 Vault —— 所以现在 alice 还读不了任何
东西。现在亲手创建它，故意把路径**写死为当前的 `secret/`**：

```bash
vault policy write app-team-a-read - <<'EOF'
path "secret/data/app-team-a/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/app-team-a/*" {
  capabilities = ["read", "list"]
}
EOF
```

检查一下刚创建的 policy，重点看路径上写的是 `secret/`：

```bash
vault policy read app-team-a-read
```

验证 alice 现在能正常读取：

```bash
ALICE_TOKEN=$(vault login -method=userpass -path=userpass \
  username=alice password=training -format=json | jq -r .auth.client_token)

echo "=== 迁移前：alice 读取 secret/app-team-a/db ==="
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/app-team-a/db 2>&1 | tail -8

export VAULT_TOKEN='root'
```

能看到 `password=s3cret-A`，说明 policy 生效、路径也命中了实际挂载点。

## 4.2 路径迁移之后：同一个 alice、同一条 policy，立刻 403

现在把 `secret/` 搬到 `kv-prod/`—— 注意我们 **什么都不改**：不改
alice、不改它的 token、也不改刚写入的 policy：

```bash
vault secrets move secret/ kv-prod/
```

```
Success! Finished moving secrets engine secret/ to kv-prod/, ...
```

再用 alice 的 token 去读新路径上的同一条数据：

```bash
echo "=== 迁移后：alice 读新路径 kv-prod/app-team-a/db ==="
VAULT_TOKEN=$ALICE_TOKEN vault kv get kv-prod/app-team-a/db 2>&1 | tail -5
export VAULT_TOKEN='root'
```

**403 Permission Denied**—— 因为 `app-team-a-read` policy 里写的还是
`secret/data/app-team-a/*`，而引擎已经搬到 `kv-prod/` 了。这就是
本节开头说的"Vault 不会帮你同步 Policy 路径"的产生后果。

## 4.3 修复 Policy

```bash
vault policy write app-team-a-read - <<'EOF'
path "kv-prod/data/app-team-a/*" {
  capabilities = ["read", "list"]
}
path "kv-prod/metadata/app-team-a/*" {
  capabilities = ["read", "list"]
}
EOF
```

再试一次：

```bash
echo "=== Policy 更新后：alice 再次读取 ==="
VAULT_TOKEN=$ALICE_TOKEN vault kv get kv-prod/app-team-a/db 2>&1 | tail -8
export VAULT_TOKEN='root'
```

成功了。

## 4.4 生产环境迁移检查清单

把整个过程归纳成一个清单：

| 步骤 | 操作 | 说明 |
| :--- | :--- | :--- |
| **1. 审计 Policy** | `vault policy list` + `grep` 旧路径 | 找出所有引用旧路径的 Policy |
| **2. 审计应用配置** | 搜索应用代码/CI 中的旧路径 | Vault API 调用、Agent 模板中的路径 |
| **3. 计划维护窗口** | 通知相关团队 | 迁移期间引擎短暂不可用 |
| **4. 执行 move** | `vault secrets move old/ new/` | 原子操作，通常秒级完成 |
| **5. 更新 Policy** | `vault policy write ...` | 把所有旧路径替换为新路径 |
| **6. 更新应用** | 修改应用中的 Vault 路径 | 或者通过 Vault Agent 模板的 alias 过渡 |
| **7. 验证** | 用受影响的身份测试读写 | 确认 Policy + 路径都生效 |

## 4.5 迁移期间的行为

几个关键细节：

- **迁移过程中引擎不可用**：从 `move` 命令发出到完成的短暂窗口内，新旧路径都不可用。对于小引擎这通常是毫秒级，但 TB 级数据的引擎可能需要更长时间
- **现有 Lease 会失效**：如果引擎有活跃的动态 Lease（比如 Database 引擎签发的临时凭据），迁移后这些 Lease 将无法续期或撤销。**迁移前应确保动态 Lease 已到期或已手动撤销**
- **审计日志会记录**：`sys/remount` 操作会完整记录在审计设备中，包含源路径、目标路径和执行者身份

## 4.6 验证所有数据仍然完好

最后做一次全量检查：

```bash
echo "=== kv-prod/（原 secret/）下的数据 ==="
vault kv list kv-prod/app-team-a/
vault kv list kv-prod/app-team-b/ 2>/dev/null || echo "(app-team-b 也在)"
vault kv get -format=json kv-prod/app-team-a/db | jq .data.data

echo ""
echo "=== archive/（原 legacy-kv/）下的数据 ==="
vault kv get -format=json archive/old-service | jq .data.data

echo ""
echo "=== 认证方法状态 ==="
vault auth list -format=table | grep -E "Path|userpass|corp"

echo ""
echo "=== 最终引擎列表 ==="
vault secrets list -format=table | grep -E "Path|kv-prod|archive"
```

三次迁移全部完成，数据完整，没有任何丢失。
