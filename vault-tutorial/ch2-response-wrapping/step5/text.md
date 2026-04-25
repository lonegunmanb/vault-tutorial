# 第五步：完整场景——AppRole SecretID 安全交付

前面四步都在用 KV 数据做演示。这一步走一个**真实生产场景**——用
response wrapping 安全交付 AppRole 的 SecretID，彻底避免 SecretID
以明文出现在任何传输链路上。

要搭起来的完整流程：

```
  CI 调度器（Operator）              CI Runner（目标服务）
  持有 admin-level token             刚启动，啥凭据都没有
  ────────────────────               ──────────────────────
  ① 申请 SecretID（wrapped）
  ② 拿到 wrapping token
  ③ 把 wrapping token 传给 Runner →  ④ 收到 wrapping token
                                     ⑤ unwrap → 拿到 SecretID
                                     ⑥ 用 RoleID + SecretID 登录 Vault
                                     ⑦ 开始正常访问机密
```

这样，**SecretID 明文从未出现在调度器一侧**——调度器只看到了
wrapping token，runner 拆封后拿到 SecretID 并立刻登录消费。

## 5.1 启用 AppRole 并创建角色

```bash
vault auth enable approle

vault write auth/approle/role/ci-runner \
  token_policies=default \
  secret_id_ttl=5m \
  token_ttl=30m \
  token_max_ttl=1h
```

拿到 RoleID（这个是固定的，可以安全地嵌入配置镜像）：

```bash
ROLE_ID=$(vault read -format=json auth/approle/role/ci-runner/role-id | jq -r .data.role_id)
echo "RoleID = $ROLE_ID"
```

## 5.2 写一条强制 wrapping 的 policy

```bash
vault policy write ci-operator - <<'EOF'
# 只能给 ci-runner 角色签发 SecretID，且必须 wrap
path "auth/approle/role/ci-runner/secret-id" {
  capabilities      = ["create", "update"]
  min_wrapping_ttl  = "30s"
  max_wrapping_ttl  = "120s"
}
EOF
```

创建调度器 token：

```bash
OPERATOR_TOKEN=$(vault token create -policy=ci-operator -format=json | jq -r .auth.client_token)
echo "Operator token = $OPERATOR_TOKEN"
```

## 5.3 调度器签发 wrapped SecretID

```bash
echo "调度器申请 wrapped SecretID:"
WRAP_JSON=$(VAULT_TOKEN=$OPERATOR_TOKEN \
  vault write -wrap-ttl=60s -format=json -f auth/approle/role/ci-runner/secret-id)

WRAP_TOKEN=$(echo $WRAP_JSON | jq -r .wrap_info.token)
WRAP_ACC=$(echo $WRAP_JSON | jq -r .wrap_info.accessor)

echo "wrapping token   = $WRAP_TOKEN"
echo "wrapping accessor = $WRAP_ACC"
```

注意——调度器**完全看不到 SecretID 的明文**。它只拿到了一个
wrapping token。

## 5.4 验证：调度器不带 `-wrap-ttl` 会被拒

```bash
echo ""
echo "调度器尝试不 wrap 直接拿 SecretID（应被拒——policy 强制 wrap）:"
VAULT_TOKEN=$OPERATOR_TOKEN vault write -f auth/approle/role/ci-runner/secret-id 2>&1 | tail -5
```

403——`ci-operator` policy 上的 `min_wrapping_ttl` 确保 SecretID 永远
不可能以明文返回。

## 5.5 Runner 侧：先 lookup 验证，再 unwrap

模拟 runner 拿到 wrapping token 后的操作——注意 runner 此时**没有任何
Vault token**，但 `sys/wrapping/lookup` 和 `vault unwrap` 对 wrapping
token 本身不需要额外认证：

```bash
echo "Runner 验证 wrapping token 来源:"
CREATION_PATH=$(vault write -format=json sys/wrapping/lookup token=$WRAP_TOKEN | jq -r .data.creation_path)
echo "creation_path = $CREATION_PATH"

if [ "$CREATION_PATH" = "auth/approle/role/ci-runner/secret-id" ]; then
  echo "✅ 来源路径匹配预期"
else
  echo "❌ 警告：来源路径不匹配！可能存在中间人攻击"
fi
```

验证通过后，拆封：

```bash
echo ""
echo "Runner unwrap 拿到 SecretID:"
SECRET_ID=$(vault unwrap -format=json $WRAP_TOKEN | jq -r .data.secret_id)
echo "SecretID = $SECRET_ID"
```

## 5.6 Runner 用 RoleID + SecretID 登录

```bash
echo ""
echo "Runner 用 AppRole 登录:"
RUNNER_TOKEN=$(vault write -format=json auth/approle/login \
  role_id=$ROLE_ID \
  secret_id=$SECRET_ID \
  | jq -r .auth.client_token)

echo "Runner 拿到的 Vault token = $RUNNER_TOKEN"

echo ""
echo "验证 token 身份:"
VAULT_TOKEN=$RUNNER_TOKEN vault token lookup | grep -E "display_name|policies|ttl"
```

整个过程中：

- **SecretID 明文只在 runner 本地出现过**——调度器从未看到；
- **传输链上只流动了 wrapping token**——即使被截获也不是 SecretID；
- **wrapping token 是一次性的**——攻击者截获后如果先拆封，runner 的
  unwrap 会失败 → **立刻触发安全警报**。

## 5.7 验证：wrapping token 已经不能再用

```bash
echo ""
echo "确认 wrapping token 已被消耗:"
vault unwrap $WRAP_TOKEN 2>&1 | tail -3
vault write sys/wrapping/lookup token=$WRAP_TOKEN 2>&1 | tail -3
```

## 5.8 调度器用 accessor 监控消费状态

调度器虽然不持有 wrapping token 本身，但保留了 accessor，可以远程
查看 runner 是否已经消费了 SecretID：

```bash
echo ""
echo "调度器用 accessor 查看 wrapping token 是否还存在:"
vault token lookup -accessor $WRAP_ACC 2>&1 | tail -3
```

如果报错说 token 不存在——说明 runner 已经成功 unwrap 了（或者 token
过期了）。调度器可以据此判断交付是否完成。

**这一步的核心结论**：

| 关键环节 | 安全保障 |
| --- | --- |
| policy 强制 `min_wrapping_ttl` | SecretID **永远不会**以明文出现在 API 响应里 |
| 调度器只拿到 wrapping token | 调度器看不到 SecretID 本身→降低内部泄露风险 |
| runner 先 lookup 验证 creation_path | 检测中间人重新包装的攻击 |
| unwrap 一次性 | 截获后拆封 → runner 发现拆不开 → **安全警报** |
| accessor 远程监控 | 调度方可以不持有 token 也能追踪消费状态 |

这就是 Response Wrapping 在生产中最经典的应用——**AppRole SecretID
安全交付管线**，也被称为对"第零号机密"问题的标准缓解方案。
