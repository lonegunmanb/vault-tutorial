# 第四步：ec2 role + mixing 拦截 + 运维端点

[4.3 章 §6](/ch4-aws) 讲过单 role 只能选一种 auth_type；[4.3 章 §8 /
§10](/ch4-aws) 讲过 ec2 方法的 `identity-accesslist` / role tag 的
`roletag-denylist` / 两个 `tidy` 端点。这一步把 ec2 role 的配置面
与这些运维端点都跑一遍。

> ⚠️ MiniStack **不模拟 EC2 instance identity document 的 PKCS#7
> 签名**——所以 ec2 方法的 login 在本环境不可能真正成功；这一步只
> 看配置面与拒绝路径。

## 4.1 建一个 ec2 类型的 role

```bash
vault write auth/aws/role/dev-role-ec2 \
    auth_type=ec2 \
    bound_ami_id=ami-12345678 \
    policies=default \
    token_max_ttl=24h
```

回读：

```bash
vault read auth/aws/role/dev-role-ec2
```

ec2 类型 role 上独有的字段（[4.3 章 §4](/ch4-aws)）：`bound_ami_id`、
`bound_account_id`、`bound_iam_role_arn`、
`bound_iam_instance_profile_arn`、`bound_subnet_id` / `bound_vpc_id` /
`bound_region`、`role_tag`、`disallow_reauthentication`、
`allow_instance_migration`。

## 4.2 写入侧 mixing 拦截：iam role 加 ec2-only 字段

```bash
vault write auth/aws/role/dev-role-iam \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:* \
    bound_ami_id=ami-12345678 \
    resolve_aws_unique_ids=false \
    policies=default
```

会立刻被 Vault 在写入时拒掉（关键词 `unable to use bound_ami_id with
auth_type iam` 或 `cannot be used with auth_type iam`）：

```
* unable to use bound_ami_id with auth_type iam ...
```

> [4.3 章 §6](/ch4-aws)：Vault 主动拦"在选定 auth_type 下根本无法生
> 效的约束"。要让 iam role 也能用 `bound_ami_id`，必须打开
> `inferred_entity_type=ec2_instance` 启用推断。

恢复 dev-role-iam（去掉 `bound_ami_id`）：

```bash
vault write auth/aws/role/dev-role-iam \
    auth_type=iam \
    bound_iam_principal_arn=arn:aws:iam::000000000000:* \
    resolve_aws_unique_ids=false \
    policies=default \
    token_ttl=10m \
    token_max_ttl=30m
```

## 4.3 登录侧 mixing 拦截：iam 风格请求打 ec2 role

iam 风格请求需要四件套——伪造一组打 dev-role-ec2：

```bash
vault write auth/aws/login \
    role=dev-role-ec2 \
    iam_http_request_method=POST \
    iam_request_url=$(echo -n 'http://127.0.0.1:4566/' | base64) \
    iam_request_body=$(echo -n 'Action=GetCallerIdentity&Version=2011-06-15' | base64) \
    iam_request_headers=$(echo -n '{}' | base64)
```

会看到（关键词 `auth method ... not allowed for role`）：

```
* auth method iam is not allowed for role dev-role-ec2
```

## 4.4 ec2 风格请求打 iam role

ec2 风格的请求只有 `pkcs7` + `role`：

```bash
vault write auth/aws/login \
    role=dev-role-iam \
    pkcs7=fake-pkcs7-signature
```

会看到 `auth method ec2 is not allowed for role dev-role-iam`。

## 4.5 ec2 真实登录的失败现场

```bash
vault write auth/aws/login \
    role=dev-role-ec2 \
    pkcs7=fake-pkcs7-signature
```

可能出现的错误关键词：`failed to verify the signature` / `unable to
verify the PKCS#7 signature` ——MiniStack 不签 IID，伪造签名也通不过
Vault 内置的 AWS 公钥验签。这正是 [4.3 章 §3](/ch4-aws) 那条 ec2 流
程的第三步"Vault verifies the signature on the PKCS#7 document"在
现场的样子。

## 4.6 列出 identity-accesslist

```bash
vault list auth/aws/identity-accesslist
```

应显示空（没有 ec2 实例真正登过）。读一条不存在的条目：

```bash
vault read auth/aws/identity-accesslist/i-1234567890abcdef0
```

返回 `No value found at ...`。如果实例真的登过，返回结构会含
`client_nonce` / `pending_time` / `disallow_reauthentication` /
`expiration_time` / `role`——[4.3 章 §8 / §9](/ch4-aws) 详述。

## 4.7 删 accesslist 条目（[4.3 章 §9](/ch4-aws) 丢 nonce 的运维路径）

```bash
vault delete auth/aws/identity-accesslist/i-1234567890abcdef0
```

幂等——条目不存在也不报错。

## 4.8 触发 accesslist tidy

```bash
vault write auth/aws/tidy/identity-accesslist safety_buffer=72h
```

`safety_buffer=72h` 与官方默认值一致（[4.3 章 §10](/ch4-aws)）；Vault
异步执行清理。

## 4.9 列出 roletag-denylist + 触发 tidy

```bash
vault list auth/aws/roletag-denylist
vault write auth/aws/tidy/roletag-denylist safety_buffer=72h
```

> 真实 role tag 是 Vault 通过 `auth/aws/role/<role>/tag` 端点生成的
> HMAC 签名串；本实验没启用 `role_tag` 字段，所以无法生成真 tag。
> 命令本身的语义与运维路径在这里就清楚了。

## 4.10 这一步的核心闭环

mixing 拦截在写入侧 + 登录侧两道关都生效；ec2 方法的 PKCS#7 验签
是 Vault 自己做（不像 iam 那样转给 AWS）；运维端点
`identity-accesslist` / `roletag-denylist` / `tidy` 的语义与
[4.3 章 §8 / §10](/ch4-aws) 完全对应。

## 收尾：清理这套实验

```bash
# 关掉 aws 认证方法 = 撕掉所有它签出来的 token + 删 role / config / accesslist / denylist
vault auth disable aws

# 停掉 MiniStack 容器
docker rm -f ministack
```

> [4.1 章](/ch4-auth-basic) 那张表里讲过的"禁用一个 Auth Method = 批
> 量登出所有通过它登录的 Token"在这里直接见效——Step 2 / Step 3 你
> 用 `vault login -method=aws` 拿到的 token 也会被一并失效。
