# 实验完成

恭喜！你已经用 LocalStack 复现了官方 Terraform + Vault Provider 教程的完整主线：

- Vault Admin 工作区创建了 Vault AWS secrets engine 与 `iam_user` 类型 role；
- Terraform Operator 工作区没有直接持有长期 AWS key，而是通过 `vault_aws_access_credentials` 现场领取短期 AWS 凭据；
- AWS provider 使用这对动态凭据创建并销毁了 LocalStack EC2 instance；
- 120 秒 TTL 到期后，Vault 自动回收了动态 IAM user；
- Admin 移除 role 中的 `ec2:*` 后，Operator 的下一次 `terraform plan` 因 EC2 权限不足失败。

## 关键回顾

| 观察点 | 含义 |
| --- | --- |
| `vault_aws_secret_backend` | Admin 把 AWS secrets engine 声明成 Terraform 管理的 Vault 资源 |
| `vault_aws_secret_backend_role` | Admin 集中定义 Operator 动态 AWS 凭据的权限边界 |
| `vault_aws_access_credentials` | Operator 在运行中向 Vault 领取短期 AWS key |
| `default_lease_ttl_seconds = 120` | 短 TTL 降低泄漏窗口，但要求 plan/apply 足够快 |
| 移除 `ec2:*` 后 plan 失败 | 权限收紧集中在 Vault role，下一次凭据签发立即生效 |

## 清理检查

如果你想手动确认环境已经干净，可以运行：

```bash
vault secrets list | grep dynamic-aws-creds || true
awslocal iam list-users --query 'Users[].UserName' --output table
awslocal ec2 describe-instances --output table || true
```

只要没有 `dynamic-aws-creds-vault-path/` 挂载、没有 `vault-...` 动态 IAM user，就说明实验核心资源已清理完毕。

## 接下来可以读

- [3.3 AWS 机密引擎](/ch3-aws)：深入理解 `iam_user`、STS、租约与 revoke 细节
- [9.1 生产环境安全加固](/ch9-production-hardening)：把这类模式放进真实上线前检查清单
- [2.3 租约（Lease）](/ch2-lease)：理解 TTL、renew、revoke 的通用生命周期模型