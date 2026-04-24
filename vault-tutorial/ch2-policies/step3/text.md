# 第三步：Parameter Constraints — 用户自助改密码

文档 §4 给的经典案例：用户只能改自己 userpass 密码，不能改自己的
policies / token_ttl 等敏感字段。

要搭起来的鉴权图：

```
  Token (alice 持有)
    │
    │ policies=[default, self-pwd]
    ▼
  Policy: self-pwd
    path "auth/userpass/users/alice"  ← 当前用户的路径
      capabilities = [update]          ← 只能 update
      allowed_parameters {
        password = []                  ← 只能改 password 字段
      }
                            (其它字段如 policies / token_ttl 自动被拒)
```

## 3.1 启用 userpass，建一个用户

```bash
vault auth enable userpass

vault write auth/userpass/users/alice \
  password=initial \
  token_policies=default
```

## 3.2 写"自助改密码"policy

为了简化教学，先用硬编码用户名 `alice`。下一步会改成 templated 版本
让它对所有用户通用。

```bash
vault policy write self-pwd - <<'EOF'
path "auth/userpass/users/alice" {
  capabilities = ["update"]
  allowed_parameters = {
    "password" = []
  }
}
EOF
```

## 3.3 把 self-pwd 挂到 alice，让她登录后自助改密码

```bash
vault write auth/userpass/users/alice token_policies=default,self-pwd
```

让 alice 登录、改自己密码：

```bash
ALICE=$(vault login -format=json -method=userpass username=alice password=initial \
  | jq -r .auth.client_token)

echo "alice 改自己密码（应成功）:"
VAULT_TOKEN=$ALICE vault write auth/userpass/users/alice password="newpwd" && echo OK
```

验证新密码生效——退出再用新密码登一次：

```bash
vault login -method=userpass username=alice password=newpwd | grep token_policies
```

## 3.4 alice 试图越权改自己的 policies / token_ttl

```bash
echo "alice 试图给自己加 admin policy（应被拒 - 参数不在 allowed_parameters 白名单里）:"
VAULT_TOKEN=$ALICE vault write auth/userpass/users/alice \
  password="newpwd" \
  token_policies="root" 2>&1 | tail -3

echo ""
echo "alice 试图改自己的 token_ttl（同样应被拒）:"
VAULT_TOKEN=$ALICE vault write auth/userpass/users/alice \
  token_ttl="9999h" 2>&1 | tail -3
```

两个都应该 403——`allowed_parameters` 是**白名单**，没列进来的参数全
部拒绝。这就是"用户能改自己密码 ≠ 用户能改自己整个账号"的边界。

## 3.5 用 `denied_parameters` 反向限制（黑名单语义）

有时候业务上能改的字段太多，写白名单累。可以反着用 `denied_parameters`
明确禁止某几个高风险字段：

```bash
vault policy write self-anything - <<'EOF'
path "auth/userpass/users/alice" {
  capabilities = ["update"]
  denied_parameters = {
    "policies"       = []
    "token_policies" = []
    "token_ttl"      = []
    "token_max_ttl"  = []
  }
}
EOF
```

效果：除了上面 4 个被禁的字段，其它字段（password / token_period 等）
都允许改。

> 注意 `denied_parameters` 的优先级**高于** `allowed_parameters`——
> 同时设了同名字段，deny 赢。

## 3.6 文档警告过的"默认值绕过"陷阱

文档 §3.1.2 提示：如果某参数有**默认值**，用户**不传**这个参数时，
denied_parameters 检查**看不到**它，会被绕过。要堵这个洞必须配合
`required_parameters` 强制要求传值：

```bash
vault policy write self-pwd-strict - <<'EOF'
path "auth/userpass/users/alice" {
  capabilities = ["update"]
  required_parameters = ["password"]   # 必须传 password
  allowed_parameters = {
    "password" = []
  }
}
EOF
```

加了 `required_parameters` 之后，alice 即使想"啥都不传糊弄过去"也会
被拒——前置防御纵深。

## 3.7 KV v2 的"参数约束行为不可预测"陷阱

文档明确写道：

> The `allowed_parameters`, `denied_parameters`, and `required_parameters`
> fields are **not supported** for policies used with the version 2 kv
> secrets engine.

这里的"不支持"不是指"完全无视"，而是**行为不可预测**。试一下就知道：

```bash
vault policy write kv-restrict - <<'EOF'
path "secret/data/foo" {
  capabilities = ["create", "update"]
  allowed_parameters = {
    "data" = []
  }
}
EOF

TOKEN=$(vault token create -policy=kv-restrict -format=json | jq -r .auth.client_token)

# 本意是"只允许 data 字段"，看起来合理——但实际被拒：
VAULT_TOKEN=$TOKEN vault kv put secret/foo anything="should-fail-but-wont"
# 403 permission denied
```

你可能以为 `allowed_parameters = { "data" = [] }` 已经放行了写入所需的
`data` 参数，但 `vault kv put` 的实际请求体里还包含 `options` 等 KV v2
引擎自动注入的参数——这些不在白名单里，所以被 policy 挡掉了。

换句话说，参数约束在 KV v2 上**不是被忽略，而是会以你意想不到的方式
生效**：合法写入也会被拦截，而换一种写法又可能绕过。**KV v2 的字段级
控制必须靠路径分割（不同 mount / 不同子路径）解决，不能靠 parameter
constraints**。这是踩 policy 时最常见的坑之一。

**这一步的核心结论**：

| 想做的事 | 用什么 |
| --- | --- |
| 只允许传特定几个参数 | `allowed_parameters` 白名单 |
| 只禁止特定几个参数 | `denied_parameters` 黑名单 |
| 强制要求带某参数（堵默认值绕过） | `required_parameters` |
| KV v2 上做字段级控制 | ❌ 参数约束行为不可预测，必须拆 path / 拆 mount |
