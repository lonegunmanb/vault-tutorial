# 第三步：验证 `bound_iam_principal_arn` 的精确匹配与通配符

[4.3 章 §4](/ch4-aws) 讲过：iam role 上的 `bound_iam_principal_arn`
是列表，登录方 ARN 命中任一即通过；列表项可以**结尾通配**。这一步
在 LocalStack 上多建一个 IAM user，用它的凭据登录、看 ARN 不匹配的
拒绝现场，再切通配符让它通过。

> 每条命令都可能失败一次再成功——配置 / 凭据切换的过程要看清楚每一
> 步当前用的是哪一对凭据。

## 3.1 在 LocalStack 上建一个 IAM user

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam create-user --user-name app-user
APP_KEY_JSON=$(aws --endpoint-url=http://127.0.0.1:4566 iam create-access-key --user-name app-user)
APP_AK=$(echo "$APP_KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
APP_SK=$(echo "$APP_KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
echo "APP_AK=$APP_AK"
echo "APP_SK=$APP_SK"
```

确认这对凭据签出来的身份 ARN：

```bash
AWS_ACCESS_KEY_ID=$APP_AK AWS_SECRET_ACCESS_KEY=$APP_SK AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url=http://127.0.0.1:4566 sts get-caller-identity
```

应返回 `arn:aws:iam::000000000000:user/app-user`。

## 3.2 用 app-user 凭据登 dev-role-iam（应被拒）

Step 2 那条 role 绑定的是 `arn:aws:iam::000000000000:user/dev-user`，
跟 `user/app-user` **不匹配**——登录会被拒：

```bash
AWS_ACCESS_KEY_ID=$APP_AK AWS_SECRET_ACCESS_KEY=$APP_SK AWS_DEFAULT_REGION=us-east-1 \
  vault login -method=aws \
    role=dev-role-iam \
    header_value=vault.example.com \
    sts_endpoint=http://127.0.0.1:4566 \
    sts_region=us-east-1
```

会看到错误（关键词 `IAM Principal ... does not belong to the role`
或 `entity is not authorized`）：

```
Error authenticating: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/auth/aws/login
Code: 400. Errors:

* IAM Principal "arn:aws:iam::000000000000:user/app-user" does not belong to the role "dev-role-iam"
```

> 这正是 [4.3 章 §4](/ch4-aws) 那条"`bound_iam_principal_arns`：列表
> 项命中任一即通过"机制——一个都没命中就直接拒。

## 3.3 把 role 改成允许该账号下任意 user

[4.3 章 §4](/ch4-aws) 讲过通配符规则：`arn:aws:iam::000000000000:*`
允许该账号下任何 principal 登录。改 role：

```bash
vault write auth/aws/role/dev-role-iam \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:* \
    resolve_aws_unique_ids=false \
    policies=default \
    token_ttl=10m \
    token_max_ttl=30m
```

> 真 AWS 上用通配符必须给 Vault `iam:GetUser` + `iam:GetRole` 权限
> 才能解析完整 path（[4.3 章 §4](/ch4-aws)）；LocalStack 上 `test/test`
> 是 root，所有调用默认就放行。

## 3.4 用 app-user 凭据再登一次（这次应成功）

```bash
unset VAULT_TOKEN
AWS_ACCESS_KEY_ID=$APP_AK AWS_SECRET_ACCESS_KEY=$APP_SK AWS_DEFAULT_REGION=us-east-1 \
  vault login -method=aws \
    role=dev-role-iam \
    header_value=vault.example.com \
    sts_endpoint=http://127.0.0.1:4566 \
    sts_region=us-east-1
```

这次应输出 `Success! ...`，`token_meta_client_arn` =
`arn:aws:iam::000000000000:user/app-user`。

切回 root：

```bash
export VAULT_TOKEN=root
```

## 3.5 这一步的核心闭环

`bound_iam_principal_arn` 在 Vault 端是硬约束——AWS 验过签名只是
"证明你是这个 ARN"，**够不够格登这个 role 还要 Vault 自己再过一道
ARN 列表 / 通配符匹配**。下一步演示 ec2 方法的配置面以及运维端点。
