# 第二步：建 iam role + 真实跑通一次 iam 登录

[4.3 章 §2](/ch4-aws) 描述的 iam 认证完整链路：客户端用本地 AWS 凭
据签一次空的 `sts:GetCallerIdentity` 请求 → 把"已签好但还没发出"的
请求四件套（method / URL / body / headers）提交给 Vault → Vault 重
组并转发给 STS → STS 验签返回身份 → Vault 据此签 token。这一步把
这条链路在 MiniStack 上**真正跑一遍**。

## 2.1 建一个 iam 类型的 role

绑定 Step 1.2 看到的那个 root ARN：

```bash
vault write auth/aws/role/dev-role-iam \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:root \
    resolve_aws_unique_ids=false \
    policies=default \
    token_ttl=10m \
    token_max_ttl=30m
```

> **特别注意 `resolve_aws_unique_ids=false`**：默认值是 `true`，
> Vault 会调 `iam:GetUser` / `iam:GetRole` 把 ARN 解析成 IAM Unique
> ID 后存进 role——**真 AWS 上这是好事**（避免"删号重建同名"被冒充），
> 但 MiniStack 对 root principal **不支持** `GetUser`，会报
> `unable to resolve unique ID`。本实验关掉这个解析。

回读确认：

```bash
vault read auth/aws/role/dev-role-iam
```

`auth_type` 必须是 `iam`，`bound_iam_principal_arns` 列表里有那个
root ARN。

## 2.2 真实登录：让 Vault CLI 替你签 GetCallerIdentity

[4.3 章 §14](/ch4-aws) 讲过：Vault CLI 已经内建了 iam 登录支持，
**自动用本地 AWS 凭据签请求**。我们再加 `sts_endpoint` 把 CLI 也
指向 MiniStack（让它签的请求 URL 就是 MiniStack 而不是真 AWS）：

```bash
vault login -method=aws \
    role=dev-role-iam \
    header_value=vault.example.com \
    sts_endpoint=http://127.0.0.1:4566/ \
    sts_region=us-east-1
```

应输出：

```
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. ...

Key                              Value
---                              -----
token                            hvs.CAESI...
token_accessor                   ...
token_duration                   10m
token_renewable                  true
token_policies                   ["default"]
identity_policies                []
policies                         ["default"]
token_meta_account_id            000000000000
token_meta_auth_type             iam
token_meta_canonical_arn         arn:aws:iam::000000000000:root
token_meta_client_arn            arn:aws:iam::000000000000:root
token_meta_client_user_id        AKIAIOSFODNN7EXAMPLE
token_meta_inferred_aws_region   n/a
token_meta_inferred_entity_id    n/a
token_meta_inferred_entity_type  n/a
token_meta_role                  dev-role-iam
```

> 几个关键点：
> - **登录成功了**：你的 shell 现在拿着的是 dev-role-iam 这个 role 签
>   出来的 Vault token，而不是 root token
> - `token_meta_client_arn` 正是 MiniStack 在 Step 1.2 返回的那个
>   ARN——证明 Vault 真的把签名转给 MiniStack 验过了
> - `header_value=vault.example.com` 必须和 Step 1.4 写的
>   `iam_server_id_header_value` 一致——Vault CLI 会把它放进签名覆
>   盖的 header 集合里
> - `token_policies` 只有 `default`，因为 role 没绑额外策略

## 2.3 验证当前 token 真是新签出来的那一枚

```bash
vault token lookup
```

应看到 `policies` 是 `[default]`、`meta` 里全是上面那批 `aws_*` /
`account_id` 字段——这就是 [4.3 章 §4](/ch4-aws) 讲过的"role 签出来
的 token 自带 metadata"。

## 2.4 回到 root，方便后面继续操作

把当前 shell 的 token 切回 root：

```bash
export VAULT_TOKEN=root
vault token lookup | head -3
```

`policies` 应回到 `[root]`。

## 2.5 反演：故意漏 `header_value`

[4.3 章 §2](/ch4-aws) 那道额外防重放 header 这次能在登录路径上看到
真效果：

```bash
vault login -method=aws \
    role=dev-role-iam \
    sts_endpoint=http://127.0.0.1:4566/ \
    sts_region=us-east-1
```

会被 Vault 端拒掉，错误信息里包含 `iam server id header values do
not match`——签名里没带 `X-Vault-AWS-IAM-Server-ID` 这个 header，
Vault 在转发前就拦下。重新加上 `header_value=` 即可恢复正常。

## 2.6 这一步的核心闭环

iam 方法的"客户端签名 → Vault 转发 → AWS 验签 → Vault 签 token"四
段链路在 MiniStack 上完整跑通；额外防重放 header 缺失会被 Vault 端
拦掉，不会到达 STS。下一步去验证 ARN 绑定的精确匹配 / 通配符。
