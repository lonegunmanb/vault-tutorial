# 实验说明

本实验复现 HashiCorp 官方 Terraform 教程 [Inject secrets into Terraform using the Vault provider](https://developer.hashicorp.com/terraform/tutorials/secrets/secrets-vault) 的主线，但把真实 AWS 替换成 LocalStack。

环境会预先准备好：

- dev 模式 Vault：`VAULT_ADDR=http://127.0.0.1:8200`，root token 为 `root`；
- Terraform CLI；
- AWS CLI 与 `awslocal`；
- 一个 LocalStack 容器：监听 `127.0.0.1:4566`，启用 IAM / STS / EC2，并打开 IAM 权限校验；
- 两个 Terraform 工作区：
  - `/root/terraform-vault-aws-localstack/vault-admin-workspace`
  - `/root/terraform-vault-aws-localstack/operator-workspace`

你将依次完成四步：

1. 在 **Vault Admin 工作区**运行 Terraform，创建 Vault 专用 IAM user、挂载 Vault AWS secrets engine，并配置一条 `iam_user` 类型 role；
2. 在 **Terraform Operator 工作区**运行 Terraform，通过 Vault provider 领取动态 AWS 凭据，再用这些凭据创建 LocalStack EC2 instance；
3. 销毁 instance，并观察动态 IAM user 在 120 秒 TTL 到期后被 Vault 回收；
4. 回到 Admin 工作区移除 role 的 `ec2:*` 权限，再到 Operator 工作区运行 `terraform plan`，验证权限不足导致失败。

> 本实验不会连接真实 AWS，也不会产生云费用。所有 AWS API 都打到本机 LocalStack。