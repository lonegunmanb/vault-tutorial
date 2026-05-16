# 第二步：Terraform Operator 领取动态 AWS 凭据创建实例

现在换成官方教程里的第二个角色：**Terraform Operator**。Operator 不直接拿长期 AWS key，而是让 Terraform Vault provider 在运行时向 Vault 申请一对短期 AWS 凭据。

进入 Operator 工作区：

```bash
cd /root/terraform-vault-aws-localstack/operator-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
```

## 2.1 看懂 Operator 工作区的凭据流向

```bash
sed -n '1,220p' main.tf
```

重点看这三段：

```hcl
data "terraform_remote_state" "admin" { ... }

data "vault_aws_access_credentials" "creds" {
  backend = data.terraform_remote_state.admin.outputs.backend
  role    = data.terraform_remote_state.admin.outputs.role
}

provider "aws" {
  access_key = data.vault_aws_access_credentials.creds.access_key
  secret_key = data.vault_aws_access_credentials.creds.secret_key
}
```

这就是官方教程的核心：AWS provider 用的不是本机长期 key，而是 Vault data source 现场返回的动态 key。

> 官方教程用 `data "aws_ami" "ubuntu"` 查询真实 AWS 的 Ubuntu AMI。本实验运行在 LocalStack 上，没有真实公共 AMI 目录，所以使用一个 LocalStack 可接受的模拟 AMI ID；同时保留 `data "aws_availability_zones" "available"`，让 `terraform plan` 阶段仍然会调用 EC2 API。这样第 4 步移除 `ec2:*` 后，权限拒绝会发生在 plan 阶段，而不是拖到 apply 阶段，失败点仍与官方教程一致。

## 2.2 初始化并应用 Operator 工作区

```bash
terraform init
terraform apply -auto-approve
terraform output
```

应输出一个 `instance_id`，形如：

```text
instance_id = "i-..."
```

这一刻发生了三件事：

1. Terraform 读取 Admin 工作区 state，拿到 Vault backend 与 role 名；
2. `vault_aws_access_credentials` 读取 `dynamic-aws-creds-vault-path/creds/dynamic-aws-creds-vault-role`；
3. Vault 在 LocalStack IAM 里创建一名动态 IAM user，AWS provider 用这名用户的 access key 创建 EC2 instance。

## 2.3 在 LocalStack 里观察动态 IAM user 与 EC2 instance

先看 IAM user：

```bash
awslocal iam list-users \
  --query 'Users[?starts_with(UserName, `vault-`)].UserName' \
  --output table
```

应看到一个以 `vault-` 开头的用户。这就是 Vault 为本次 Terraform run 创建的短期 IAM user。

再看 EC2 instance：

```bash
awslocal ec2 describe-instances \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

应看到 `dynamic-aws-creds-operator-instance`。官方教程是在 AWS Console 的 EC2 页面看这一项，本实验用 CLI 看 LocalStack 的模拟对象。

## 2.4 在 Vault 里观察 lease

```bash
ADMIN_BACKEND=$(terraform -chdir=../vault-admin-workspace output -raw backend)
ADMIN_ROLE=$(terraform -chdir=../vault-admin-workspace output -raw role)

vault list "sys/leases/lookup/${ADMIN_BACKEND}/creds/${ADMIN_ROLE}" || true
```

如果 lease 尚未过期，这里会列出一个 lease 后缀。它对应的完整 lease ID 形如：

```text
dynamic-aws-creds-vault-path/creds/dynamic-aws-creds-vault-role/<lease-suffix>
```

这份 lease 到期后，Vault 会回到 IAM 端删除对应的动态 IAM user。

---

## ✅ 验收

- [ ] `terraform apply -auto-approve` 成功
- [ ] `terraform output` 显示一个 `instance_id`
- [ ] `awslocal iam list-users` 能看到 `vault-...` 动态 IAM user
- [ ] `awslocal ec2 describe-instances` 能看到 `dynamic-aws-creds-operator-instance`

下一步销毁 instance，并观察 Terraform destroy 也会向 Vault 领取一组新的短期 AWS 凭据。