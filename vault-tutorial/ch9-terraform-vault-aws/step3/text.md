# 第三步：销毁实例并观察动态 IAM 凭据回收

官方教程在创建 EC2 实例后，会让 Operator 运行 `terraform destroy`。这一点也很有教学价值：destroy 不是「沿用上一次 apply 的长期 key」，而是再次通过 Vault data source 领取一对短期 AWS 凭据，再用它删除资源。

## 3.1 销毁 LocalStack EC2 instance

```bash
cd /root/terraform-vault-aws-localstack/operator-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

terraform destroy -auto-approve
```

销毁完成后确认 instance 已不再处于 running 列表：

```bash
awslocal ec2 describe-instances \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

LocalStack 可能仍返回 terminated 记录，这是 EC2 API 的正常语义；重点是 Terraform state 中已经没有 `aws_instance.main`：

```bash
terraform state list || true
```

## 3.2 观察 destroy 也创建了短期 IAM user

```bash
awslocal iam list-users \
  --query 'Users[?starts_with(UserName, `vault-`)].UserName' \
  --output table
```

你可能会看到一个或多个 `vault-...` 用户：apply 曾创建过一组动态凭据，destroy 又创建过一组动态凭据。它们都只活 120 秒。

## 3.3 等待 TTL 到期，确认 Vault 回收动态 IAM user

官方教程建议回到 Vault server 日志里看 `expiration: revoked lease`。本实验更直观：直接等 130 秒，再问 LocalStack 还有没有 `vault-` 开头的 IAM user。

```bash
echo "等待 130 秒，让 120 秒 lease 自然到期..."
sleep 130

awslocal iam list-users \
  --query 'Users[?starts_with(UserName, `vault-`)].UserName' \
  --output table
```

应当不再看到 `vault-...` 动态用户。Vault 已经根据 lease 生命周期调用 IAM 删除了它们。

> 这就是动态凭据和静态凭据最根本的差别：静态 key 泄漏后必须靠人记得去删；动态 key 从诞生那一刻起就带着 lease，过期会被系统回收。

---

## ✅ 验收

- [ ] `terraform destroy -auto-approve` 成功
- [ ] Operator 工作区 state 中不再有 `aws_instance.main`
- [ ] 120 秒 TTL 到期后，LocalStack 中 `vault-...` 动态 IAM user 消失

下一步回到 Admin 工作区，把 role 里的 `ec2:*` 移除，验证 Operator 下一次 plan 会失败。