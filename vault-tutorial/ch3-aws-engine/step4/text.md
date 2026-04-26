# 第四步：Policy 路径踩坑——`creds/` vs `sts/` vs `config/`

3.3 §7 的核心警告：**给应用开放 `aws/creds/*` 等于让它能拿所有 Role
的凭据**。这一步亲手写一份"只能取 `s3-app` 的 `iam_user` 凭据"的最
小 Policy，并故意触发几个 403 把速查表变成肌肉记忆。

## 4.1 准备测试身份 alice

```bash
vault auth enable userpass 2>/dev/null || echo "userpass 已启用"
vault write auth/userpass/users/alice \
  password=training \
  policies=aws-s3-app

ALICE_TOKEN=$(vault login -method=userpass \
  username=alice password=training \
  -format=json | jq -r .auth.client_token)
echo "alice token = $ALICE_TOKEN"
```

`aws-s3-app` policy 还没创建，alice 现在什么都拿不到。

## 4.2 第一版 Policy：写得过宽

```bash
vault policy write aws-s3-app - <<'EOF'
# 故意写成 aws/creds/* 通配——意图是"alice 能取 s3-app 的凭据"
path "aws/creds/*" {
  capabilities = ["read"]
}
EOF
```

验证 alice 现在能取 `s3-app`：

```bash
echo "=== alice 取 s3-app（应成功）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/creds/s3-app | head -8
export VAULT_TOKEN='root'
```

但**她也能取你不希望她碰的 Role**——这是过宽通配的恶果。先证明这一点：
临时再造一个"超大权限"的 Role 模拟"管理员才能取的凭据"：

```bash
cat > /root/admin-policy.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": "*", "Resource": "*" }] }
EOF
vault write aws/roles/admin-all \
  credential_type=iam_user \
  policy_document=@/root/admin-policy.json

echo "=== alice 也能取 admin-all（不该能！）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/creds/admin-all | head -5
export VAULT_TOKEN='root'
```

果然返回了一对 AK/SK——alice 拿到了 `*:*` 的管理员凭据，问题严重。

## 4.3 修复 Policy：按 Role 名精确写到末端

```bash
vault policy write aws-s3-app - <<'EOF'
# 只允许这一条 Role
path "aws/creds/s3-app" {
  capabilities = ["read"]
}
EOF
```

不需要让 alice 重新登录——Vault 在每次请求时**实时**评估 policy。

```bash
echo "=== alice 取 s3-app（应成功）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/creds/s3-app | head -5
export VAULT_TOKEN='root'

echo ""
echo "=== alice 取 admin-all（应被拒绝）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/creds/admin-all 2>&1 | tail -3
export VAULT_TOKEN='root'
```

第二条返回 `permission denied`——按 Role 名精确授权才是正确姿势。

## 4.4 路径段错配踩坑：`creds/` 写成 `sts/`

如果给 alice 的 Role 改成 `assumed_role` 类型，她就得走 `sts/`。
现在故意只给她 `creds/` 的权限：

```bash
vault policy write aws-s3-app - <<'EOF'
path "aws/creds/s3-app"   { capabilities = ["read"] }
path "aws/creds/s3-assume" { capabilities = ["read"] }   # ← 路径段写错
EOF

echo "=== alice 走 sts/ 取 s3-assume（应被拒）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/sts/s3-assume 2>&1 | tail -3
export VAULT_TOKEN='root'
```

返回 403——policy 写的是 `aws/creds/s3-assume`，但 `assumed_role` 的
HTTP 端点是 `aws/sts/s3-assume`，**完全没匹配上**。修正：

```bash
vault policy write aws-s3-app - <<'EOF'
path "aws/creds/s3-app"   { capabilities = ["read"] }
path "aws/sts/s3-assume"  { capabilities = ["read"] }
EOF

echo "=== 修正后 alice 走 sts/ 取 s3-assume（应成功）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/sts/s3-assume | head -5
export VAULT_TOKEN='root'
```

## 4.5 防止应用碰配置面：明示拒绝 `config/*`

应用 token 不应该能修改 `aws/config/root`、不应该能触发 `rotate-root`、
不应该能改 lease 默认值。**默认就拒绝**（policy 里没 path 就是拒绝）
其实已经够，但很多团队习惯显式 deny 让审查者一眼看明白意图：

```bash
echo "=== alice 试图读 root config（应被拒）==="
VAULT_TOKEN=$ALICE_TOKEN vault read aws/config/root 2>&1 | tail -3
export VAULT_TOKEN='root'

echo ""
echo "=== alice 试图触发 rotate-root（应被拒）==="
VAULT_TOKEN=$ALICE_TOKEN vault write -force aws/config/rotate-root 2>&1 | tail -3
export VAULT_TOKEN='root'
```

两条都 403——因为我们的 policy **完全没提及** `aws/config/*`，按
Vault "拒绝优先"原则就是禁止。

## 4.6 Policy 路径速查（AWS 引擎）

| 想做的事 | 路径 | capability |
| --- | --- | --- |
| 配置 root key | `aws/config/root` | `create` / `update` |
| 触发自动轮转 root | `aws/config/rotate-root` | `update` |
| 调 lease 默认值 | `aws/config/lease` | `create` / `update` |
| 写 / 读单条 Role | `aws/roles/<name>` | `create` / `read` / `update` / `delete` |
| 列 Role | `aws/roles/` | `list` |
| 取 `iam_user` / `federation_token` 凭据 | `aws/creds/<role>` | `read` |
| 取 `assumed_role` 凭据 | `aws/sts/<role>` | `read` |

> **三条铁律**：
> 1. **永远写到 Role 名这一层**——不要 `aws/creds/*`、不要 `aws/sts/*`
> 2. **`iam_user` 走 `creds/`，`assumed_role` 走 `sts/`**——路径段
>    错了所有 capability 都白配
> 3. **`config/*` 一律默认拒绝**——只有运维 token / Terraform 配置
>    流水线该有这部分权限

---

> 接下来回到 finish 页面回顾本实验的全部要点。
