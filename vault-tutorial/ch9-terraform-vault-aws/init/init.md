# 实验说明

本实验复现 HashiCorp 官方 Terraform 教程 [Inject secrets into Terraform using the Vault provider](https://developer.hashicorp.com/terraform/tutorials/secrets/secrets-vault) 的主线，但把真实 AWS 替换成 MiniStack。

环境会预先准备好：

- dev 模式 Vault：`VAULT_ADDR=http://127.0.0.1:8200`，root token 为 `root`；
- Terraform CLI；
- AWS CLI 与 `awslocal`；
- 一个 MiniStack 容器：监听 `127.0.0.1:4566`，启用 IAM / STS / EC2，并打开 IAM 权限校验；
- 两个 Terraform 工作区：
  - `/root/terraform-vault-aws-ministack/vault-admin-workspace`
  - `/root/terraform-vault-aws-ministack/operator-workspace`

你将依次完成四步：

1. 在 **Vault Admin 工作区**运行 Terraform，创建 Vault 专用 IAM user、挂载 Vault AWS secrets engine，并配置一条 `iam_user` 类型 role；
2. 在 **Terraform Operator 工作区**先直连 Vault：`apply_delay=0s` 的短 apply 成功，`apply_delay=150s` 的长 apply 因 120 秒 TTL 到期失败；
3. Terraform 文件一行不改，只启动 **Vault Proxy** 并把 Terraform 的 Vault 请求改走 Proxy listener，让同一条 `apply_delay=150s` 长 apply 成功；
4. 回到 Admin 工作区移除 role 的 `ec2:*` 权限，再到 Operator 工作区运行 `terraform plan`，验证权限不足导致失败。

> 本实验不会连接真实 AWS，也不会产生云费用。所有 AWS API 都打到本机 MiniStack。