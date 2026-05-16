# 第一步：Vault Admin 工作区配置 AWS secrets engine

官方教程的第一幕由 **Vault Admin** 执行：平台团队先把「动态 AWS 凭据怎么签发」写进 Vault。这里的 Terraform 不是去创建业务基础设施，而是在创建一座凭据工厂。

本实验已经生成了 `vault-admin-workspace`，先进入目录：

```bash
cd /root/terraform-vault-aws-localstack/vault-admin-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
```

## 1.1 看懂 Admin 工作区的四类资源

```bash
sed -n '1,220p' main.tf
```

请把文件按四段读：

1. `provider "aws"`：在官方教程里它指向真实 AWS；本实验通过 `endpoints` 把 IAM / STS / EC2 都指向 `http://127.0.0.1:4566`；
2. `aws_iam_user` / `aws_iam_access_key` / `aws_iam_user_policy`：创建一个给 Vault AWS secrets engine 使用的 IAM user；
3. `vault_aws_secret_backend`：把 AWS secrets engine 挂到 Vault，并把刚生成的 access key / secret key 写进去；
4. `vault_aws_secret_backend_role`：创建 role，定义将来 Operator 领到的动态 IAM user 有哪些 AWS 权限。

> `default_lease_ttl_seconds = 120` 对齐官方教程：动态 AWS 凭据默认只活 120 秒。它从 `vault_aws_access_credentials` data source 被读取的那一刻开始倒计时。

## 1.2 初始化并应用 Admin 工作区

```bash
terraform init
terraform apply -auto-approve
```

`-auto-approve` 是本实验为了避免人工等待耗尽 120 秒 TTL 做的本地化调整。官方教程里是交互式 `terraform apply` 后输入 `yes`，机制相同。

应用完成后看两个输出：

```bash
terraform output
```

应看到类似：

```text
backend = "dynamic-aws-creds-vault-path"
role = "dynamic-aws-creds-vault-role"
```

这两个值会被 Operator 工作区通过 `terraform_remote_state` 读取。

## 1.3 在 Vault 侧确认 AWS secrets engine 已挂载

```bash
vault secrets list | grep dynamic-aws-creds

vault read "$(terraform output -raw backend)/config/root"
vault read "$(terraform output -raw backend)/roles/$(terraform output -raw role)"
```

你应看到：

- secrets engine 挂载路径是 `dynamic-aws-creds-vault-path/`；
- `iam_endpoint` 与 `sts_endpoint` 都指向 `http://127.0.0.1:4566`；
- role 的 `credential_type` 是 `iam_user`；
- role 的 policy 初始包含 `iam:*` 与 `ec2:*`。

`secret_key` 不会从 Vault 回显，这符合 Vault 对敏感字段的处理方式。

## 1.4 在 LocalStack 侧确认 Vault 专用 IAM user 已创建

```bash
awslocal iam list-users --query 'Users[].UserName' --output table
```

应看到 `dynamic-aws-creds-vault-user`。这是 **Vault 自己**后续用来创建动态 IAM user 的身份，不是 Operator 直接使用的身份。

---

## ✅ 验收

- [ ] `terraform output` 显示 `backend` 与 `role`
- [ ] `vault secrets list` 里出现 `dynamic-aws-creds-vault-path/`
- [ ] `vault read .../roles/...` 里能看到 `credential_type=iam_user`
- [ ] `awslocal iam list-users` 里能看到 `dynamic-aws-creds-vault-user`

下一步切到 Operator 工作区，让 Terraform 在运行中向 Vault 领取临时 AWS 凭据。