# 第二步：建 IAM user + iam role + 真实跑通一次 iam 登录

[4.3 章 §2](/ch4-aws) 描述的 iam 认证完整链路：客户端用本地 AWS 凭
据签一次空的 `sts:GetCallerIdentity` 请求 → 把"已签好但还没发出"的
请求四件套（method / URL / body / headers）提交给 Vault → Vault 重
组并转发给 STS → STS 验签返回身份 → Vault 据此签 token。这一步把
这条链路在 MiniStack 上**真正跑一遍**。

## 2.1 建一个能登录的 IAM user

Step 1.2 看到的 root ARN 只是确认 STS 可用；Vault 的 iam auth 会把
返回 ARN 解析成 `user/...`、`role/...` 或 `assumed-role/...` 这类普通
IAM principal，`arn:aws:iam::000000000000:root` 会被拒掉。所以先建
一个真正的 user，并抓出它的 access key：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam create-user --user-name dev-user
DEV_KEY_JSON=$(aws --endpoint-url=http://127.0.0.1:4566 iam create-access-key --user-name dev-user)
DEV_AK=$(echo "$DEV_KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
DEV_SK=$(echo "$DEV_KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
echo "DEV_AK=$DEV_AK"
echo "DEV_SK=$DEV_SK"
```

用这对凭据直连 STS，确认签出来的是 `user/dev-user`：

```bash
AWS_ACCESS_KEY_ID=$DEV_AK AWS_SECRET_ACCESS_KEY=$DEV_SK AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url=http://127.0.0.1:4566 sts get-caller-identity
```

应看到 `Arn` 为 `arn:aws:iam::000000000000:user/dev-user`。

## 2.2 建一个 iam 类型的 role

把 role 绑定到刚才的 `dev-user` ARN：

```bash
vault write auth/aws/role/dev-role-iam \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:user/dev-user \
    resolve_aws_unique_ids=false \
    policies=default \
    token_ttl=10m \
    token_max_ttl=30m
```

> **特别注意 `resolve_aws_unique_ids=false`**：默认值是 `true`，
> Vault 会调 `iam:GetUser` / `iam:GetRole` 把 ARN 解析成 IAM Unique
> ID 后存进 role——**真 AWS 上这是好事**（避免"删号重建同名"被冒充）。
> 本实验为了把重点放在 iam 登录链路上，直接按 ARN 绑定。

回读确认：

```bash
vault read auth/aws/role/dev-role-iam
```

`auth_type` 必须是 `iam`，`bound_iam_principal_arns` 列表里有
`arn:aws:iam::000000000000:user/dev-user`。

## 2.3 真实登录：让 Vault CLI 替你签 GetCallerIdentity

[4.3 章 §14](/ch4-aws) 讲过：Vault CLI 已经内建了 iam 登录支持，
**自动用本地 AWS 凭据签请求**。我们用 `dev-user` 的凭据签名，并让
CLI 指向 [Step 1.3](#) 那个 Content-Type 改写 shim（跟 [Step 1.5](#)
里服务端 `config/client` 的 `sts_endpoint` 一致）：

```bash
unset VAULT_TOKEN
AWS_ACCESS_KEY_ID=$DEV_AK AWS_SECRET_ACCESS_KEY=$DEV_SK AWS_DEFAULT_REGION=us-east-1 \
    vault login -method=aws \
        role=dev-role-iam \
        header_value=vault.example.com \
        sts_endpoint=http://127.0.0.1:4567 \
        sts_region=us-east-1
```

> 先 `unset VAULT_TOKEN` 是因为实验环境默认 `export VAULT_TOKEN=root`。
> `vault login` 会把新 token 写进 token helper，但它不能改掉当前
> shell 里已经 export 的环境变量；不 unset 的话，后面的 `vault token
> lookup` 仍会优先看到 root token。

> 两侧的 `sts_endpoint` **必须完全一致**（同样不带尾 `/`）——CLI
> 签名覆盖的 URL、Host header 都会按这个值走，Vault 服务端重组
> 转发时也走同一个。一旦 shim 路径上看到 `application/xml`，会
> 重写为 `text/xml`，Vault 的 `submitCallerIdentityRequest` 才会接
> 受这个响应。跳过 shim 直接指 4566 会被 Vault 拒为
> `body of GetCallerIdentity is invalid`（误导性错误，实际是 response
> Content-Type 不匹配）。

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
token_meta_canonical_arn         arn:aws:iam::000000000000:user/dev-user
token_meta_client_arn            arn:aws:iam::000000000000:user/dev-user
token_meta_client_user_id        ...
token_meta_inferred_aws_region   n/a
token_meta_inferred_entity_id    n/a
token_meta_inferred_entity_type  n/a
token_meta_role                  dev-role-iam
```

> 几个关键点：
> - **登录成功了**：token helper 现在存的是 dev-role-iam 这个 role 签
>   出来的 Vault token，而不是 root token
> - `token_meta_client_arn` 正是 `dev-user` 的 ARN——证明 Vault 真的把
>   签名转给 MiniStack 验过了
> - `header_value=vault.example.com` 必须和 Step 1.5 写的
>   `iam_server_id_header_value` 一致——Vault CLI 会把它放进签名覆盖
>   的 header 集合里
> - `token_policies` 只有 `default`，因为 role 没绑额外策略

## 2.4 验证当前 token 真是新签出来的那一枚

```bash
vault token lookup
```

应看到 `policies` 是 `[default]`、`meta` 里有 `client_arn` /
`canonical_arn` / `auth_type` / `account_id` 等字段——这就是
[4.3 章 §4](/ch4-aws) 讲过的"role 签出来的 token 自带 metadata"。

## 2.5 回到 root，方便后面继续操作

把当前 shell 的 token 切回 root：

```bash
export VAULT_TOKEN=root
vault token lookup | head -3
```

`policies` 应回到 `[root]`。

## 2.6 反演：故意漏 `header_value`

[4.3 章 §2](/ch4-aws) 那道额外防重放 header 这次能在登录路径上看到
真效果：

```bash
AWS_ACCESS_KEY_ID=$DEV_AK AWS_SECRET_ACCESS_KEY=$DEV_SK AWS_DEFAULT_REGION=us-east-1 \
    vault login -method=aws \
        role=dev-role-iam \
        sts_endpoint=http://127.0.0.1:4567 \
        sts_region=us-east-1
```

会被 Vault 端拒掉，错误信息里包含 `iam server id header values do
not match`——签名里没带 `X-Vault-AWS-IAM-Server-ID` 这个 header，
Vault 在转发前就拦下。重新加上 `header_value=` 即可恢复正常。

## 2.7 这一步的核心闭环

iam 方法的"客户端签名 → Vault 转发 → AWS 验签 → Vault 签 token"四
段链路在 MiniStack 上完整跑通；root ARN 不是可登录的普通 IAM
principal，真实登录要用 `user/...` 或 `role/...` 这类身份；额外防重放
header 缺失会被 Vault 端拦掉，不会到达 STS。下一步去验证 ARN 绑定
的精确匹配 / 通配符。
