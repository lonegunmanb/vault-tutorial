# 第四步：收紧 Vault role 权限并验证 plan 失败

官方教程最后一幕是权限治理：Vault Admin 决定不再允许 Terraform Operator 管 EC2，于是只修改 Vault role 的 policy，下一次 Operator 运行 Terraform 就会失败。

这一步证明：权限边界已经集中在 Vault role 上，而不是散落在每个人手里的长期 AWS key 上。

## 4.1 从 role policy 中移除 `ec2:*`

```bash
cd /root/terraform-vault-aws-ministack/vault-admin-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=1

perl -0pi -e 's/"iam:\*", "ec2:\*"/"iam:*"/' main.tf
grep -A8 '"Action"' main.tf
```

现在 role 的 `Action` 列表里只剩 `iam:*`。

应用这次变更：

```bash
terraform apply -auto-approve
```

回读 Vault role：

```bash
vault read "$(terraform output -raw backend)/roles/$(terraform output -raw role)"
```

确认 `policy_document` 中已经没有 `ec2:*`。

## 4.2 Operator 再次 plan，应因 EC2 权限不足失败

```bash
cd /root/terraform-vault-aws-ministack/operator-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=1

terraform plan -no-color 2>&1 | tee /tmp/terraform-plan-denied.log
```

期望看到类似错误：

```text
AccessDenied: User is not authorized to perform: ec2:DescribeAvailabilityZones
```

用 grep 抓关键字：

```bash
grep -Ei 'UnauthorizedOperation|AccessDenied|not authorized|not authorised' /tmp/terraform-plan-denied.log
```

这里的失败链路非常重要：Operator 仍然能向 Vault 要到一对动态 IAM key，因为 role 还允许 `iam:*`；但这对新 key 已经没有 `ec2:*`，所以 AWS provider 调 EC2 API 时被 MiniStack 拒绝。真实 AWS 中也是同一类结果。

## 4.3 清理 Admin 工作区

Operator 工作区在第 3 步已经 destroy 过，这里清理 Admin 工作区创建的 Vault backend 与 Vault 专用 IAM user：

```bash
cd /root/terraform-vault-aws-ministack/vault-admin-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=1

terraform destroy -auto-approve
```

确认 Vault 中的挂载点已消失：

```bash
vault secrets list | grep dynamic-aws-creds || true
```

没有输出即可。

---

## ✅ 验收

- [ ] Admin 工作区成功把 role policy 改为只包含 `iam:*`
- [ ] Operator 工作区 `terraform plan` 返回授权失败
- [ ] Admin 工作区 `terraform destroy` 成功清理 Vault backend 与 MiniStack IAM user

你已经复现了官方教程的完整闭环：配置 Vault AWS secrets engine、用 Vault provider 注入动态 AWS 凭据、用短期凭据运行 Terraform、再通过收紧 Vault role 让后续 Terraform 运行失去 EC2 权限。