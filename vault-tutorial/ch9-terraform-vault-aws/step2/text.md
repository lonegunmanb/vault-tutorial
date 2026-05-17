# 第二步：固定 120 秒 TTL：短 apply 成功，长 apply 失败

现在换成官方教程里的第二个角色：**Terraform Operator**。Operator 不直接拿长期 AWS key，而是让 Terraform Vault provider 在运行时向 Vault 申请一对短期 AWS 凭据。

本步先故意使用「直连 Vault Server + 固定 120 秒 TTL」这条最小链路，观察两个结果：短 apply 成功，长 apply 失败。第三步会保持 Terraform 文件一行不改，只把 Vault 接入方式换成 Vault Proxy，让同一条长 apply 成功。

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

重点看这四段：

```hcl
data "terraform_remote_state" "admin" { ... }

data "vault_generic_secret" "creds" {
  path = "${data.terraform_remote_state.admin.outputs.backend}/creds/${data.terraform_remote_state.admin.outputs.role}"
}

resource "time_sleep" "after_vault_credentials" {
  create_duration = var.apply_delay

  triggers = {
    lease_id    = data.vault_generic_secret.creds.lease_id
    apply_delay = var.apply_delay
  }
}

provider "aws" {
  access_key = data.vault_generic_secret.creds.data["access_key"]
  secret_key = data.vault_generic_secret.creds.data["secret_key"]
}
```

这就是官方教程的核心：AWS provider 用的不是本机长期 key，而是 Vault data source 现场返回的动态 key。

> 官方教程使用专门的 `vault_aws_access_credentials` data source。它在真实 AWS 中很合适，但当前 Vault provider 版本会在返回前用 AWS SDK 调真实 IAM 做一次凭据有效性校验，且这个校验没有 LocalStack endpoint 参数。因此本实验用通用的 `vault_generic_secret` 读取同一个 `${backend}/creds/${role}` 路径；Vault AWS secrets engine 签发动态 IAM user、返回 lease、到期回收的行为完全相同，只是跳过了这个真实 AWS 校验。

> 官方教程用 `data "aws_ami" "ubuntu"` 查询真实 AWS 的 Ubuntu AMI。本实验运行在 LocalStack 上，没有真实公共 AMI 目录，所以使用一个 LocalStack 可接受的模拟 AMI ID；同时保留 `data "aws_availability_zones" "available"`，让 `terraform plan` 阶段仍然会调用 EC2 API。这样第 4 步移除 `ec2:*` 后，权限拒绝会发生在 plan 阶段，而不是拖到 apply 阶段，失败点仍与官方教程一致。

## 2.2 初始化 Operator 工作区

```bash
terraform init
```

这一步会下载 `aws`、`vault` 与 `time` 三个 provider。`time_sleep` 资源只用来模拟「Terraform 已经拿到 Vault 动态 AWS 凭据，但真正调用 EC2 API 之前中间耗时很久」。它的 `triggers` 里包含 `lease_id`，所以每次 Vault 签发新 lease 时都会重新等待一次。

## 2.3 短 apply：成功后立刻观察凭据和实例

下面这一整段请一次性运行。动态 IAM user 默认只有 120 秒 TTL，如果把 `terraform apply`、`terraform output` 和 `awslocal` 观察拆开执行，中途停下来读文档或离开一会儿，回来时那名动态用户可能已经被 Vault 回收了。

```bash
terraform apply -auto-approve -var='apply_delay=0s'
terraform output

echo
echo "== Dynamic IAM users =="
awslocal iam list-users \
  --query "Users[?starts_with(UserName, 'vault-')].UserName" \
  --output table

echo
echo "== EC2 instances =="
awslocal ec2 describe-instances \
  --query "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

echo
echo "== Vault leases =="
ADMIN_BACKEND=$(terraform -chdir=../vault-admin-workspace output -raw backend)
ADMIN_ROLE=$(terraform -chdir=../vault-admin-workspace output -raw role)
vault list "sys/leases/lookup/${ADMIN_BACKEND}/creds/${ADMIN_ROLE}" || true
```

结果里应看到四类信息：

1. `terraform output` 输出一个 `instance_id`，形如 `instance_id = "i-..."`；
2. `== Dynamic IAM users ==` 下面有一个以 `vault-` 开头的用户，这是 Vault 为本次 Terraform run 创建的短期 IAM user；
3. `== EC2 instances ==` 下面能看到 `dynamic-aws-creds-operator-instance`，官方教程是在 AWS Console 的 EC2 页面看这一项，本实验用 CLI 看 LocalStack 的模拟对象；
4. `== Vault leases ==` 下面如果 lease 尚未过期，会列出一个 lease 后缀，对应的完整 lease ID 形如：

```text
dynamic-aws-creds-vault-path/creds/dynamic-aws-creds-vault-role/<lease-suffix>
```

这份 lease 到期后，Vault 会回到 IAM 端删除对应的动态 IAM user。

这一刻发生了三件事：Terraform 读取 Admin 工作区 state，拿到 Vault backend 与 role 名；`vault_generic_secret` 读取 `dynamic-aws-creds-vault-path/creds/dynamic-aws-creds-vault-role`；Vault 在 LocalStack IAM 里创建一名动态 IAM user，AWS provider 用这名用户的 access key 创建 EC2 instance。

## 2.4 清理短 apply 创建的 instance

为了让后面的长 apply 从干净状态开始，先销毁刚才创建的 instance。这里仍然使用短延时，避免 destroy 自己也等 150 秒：

```bash
terraform destroy -auto-approve -var='apply_delay=0s'
terraform state list || true
```

LocalStack 可能仍返回 terminated instance 记录，这是 EC2 API 的正常语义；重点是 Terraform state 中已经没有 `aws_instance.main`。

## 2.5 长 apply：同一份 Terraform 代码，`apply_delay=150s` 失败

现在不改任何 `.tf` 文件，只把变量改成 `apply_delay=150s`：Terraform 会先通过 Vault data source 读取一对 120 秒 TTL 的动态 AWS key，然后 `time_sleep` 等 150 秒，再让 AWS provider 调 EC2 API。

```bash
terraform apply -auto-approve -var='apply_delay=150s' -no-color 2>&1 | tee /tmp/static-ttl-long-apply.log
STATIC_STATUS=${PIPESTATUS[0]}

echo "terraform exit code: $STATIC_STATUS"
grep -Ei 'UnauthorizedOperation|AccessDenied|InvalidClientTokenId|not authorized|expired|failed' /tmp/static-ttl-long-apply.log | tail -10
```

期望结果是失败。失败原因不是 Terraform 代码写错，而是这条链路里没有任何组件替这次 Vault 读取拿到的 lease 续期；150 秒后，Vault 已经回收动态 IAM user，AWS provider 手里的 access key 也就失效了。

旁证这一点：

```bash
awslocal iam list-users \
  --query "Users[?starts_with(UserName, 'vault-')].UserName" \
  --output table
```

通常已经看不到那名长 apply 使用的动态用户。

---

## ✅ 验收

- [ ] `terraform apply -auto-approve -var='apply_delay=0s'` 成功
- [ ] `terraform output` 显示一个 `instance_id`
- [ ] `awslocal iam list-users` 能看到 `vault-...` 动态 IAM user
- [ ] `awslocal ec2 describe-instances` 能看到 `dynamic-aws-creds-operator-instance`
- [ ] `terraform destroy -auto-approve -var='apply_delay=0s'` 后 state 为空
- [ ] `terraform apply -auto-approve -var='apply_delay=150s'` 失败，日志里能看到授权 / 凭据失效相关错误

下一步不改 Terraform 文件，只改 Vault 接入方式：启动 Vault Proxy，让 Proxy 替动态 lease 续期，再跑同一条 `apply_delay=150s` 长 apply。