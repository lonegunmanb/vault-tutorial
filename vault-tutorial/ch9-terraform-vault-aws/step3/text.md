# 第三步：Terraform 代码不改，改走 Vault Proxy 后长 apply 成功

第二步已经证明：同一份 Terraform 代码在直连 Vault Server 时，`apply_delay=150s` 会因为 120 秒 lease 到期而失败。现在我们保持 Terraform 文件一行不改，只改 Vault 侧接入方式：启动一个 Vault Proxy，用 AppRole auto-auth 拿到受控 token，并让 Terraform Vault provider 通过 Proxy listener 请求动态 AWS 凭据。

关键目标：同一条命令 `terraform apply -auto-approve -var='apply_delay=150s'`，这次成功。

## 3.1 在 Vault 里创建给 Proxy 使用的最小权限身份

Proxy 不能直接用 root token。先为它写一条最小 policy：只允许读 Admin 工作区创建的 AWS dynamic credentials 路径。

```bash
cd /root/terraform-vault-aws-ministack/vault-admin-workspace

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=1

ADMIN_BACKEND=$(terraform output -raw backend)
ADMIN_ROLE=$(terraform output -raw role)

cat > /root/terraform-operator-vault-policy.hcl <<EOF
path "${ADMIN_BACKEND}/creds/${ADMIN_ROLE}" {
  capabilities = ["read"]
}
EOF

vault policy write terraform-operator-dynamic-aws /root/terraform-operator-vault-policy.hcl
vault policy read terraform-operator-dynamic-aws
```

启用 AppRole，并创建一条给 Proxy auto-auth 使用的 role：

```bash
vault auth enable approle 2>/dev/null || true

vault write auth/approle/role/terraform-proxy \
  token_policies=terraform-operator-dynamic-aws \
  token_ttl=5m \
  token_max_ttl=20m \
  secret_id_ttl=10m

vault read -field=role_id auth/approle/role/terraform-proxy/role-id > /root/terraform-proxy-role-id
vault write -f -field=secret_id auth/approle/role/terraform-proxy/secret-id > /root/terraform-proxy-secret-id
chmod 600 /root/terraform-proxy-role-id /root/terraform-proxy-secret-id
```

> `token_ttl=5m` 给 Proxy 自己的 token 留出更宽裕的续期窗口。Proxy 不只会续动态 secret lease，也会续它自己 auto-auth 拿到的 token。

## 3.2 启动带 cache 的 Vault Proxy

写一份 Proxy 配置。它做三件事：用 AppRole 自动登录 Vault；开启 cache；在 `127.0.0.1:8100` 监听 Terraform 的 Vault API 请求。

```bash
cat > /root/terraform-vault-proxy.hcl <<'EOF'
vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/terraform-proxy-role-id"
      secret_id_file_path                 = "/root/terraform-proxy-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/root/terraform-proxy-token"
    }
  }
}

cache {}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
EOF

pkill -f 'vault proxy -config=/root/terraform-vault-proxy.hcl' 2>/dev/null || true
rm -f /root/terraform-proxy-token /root/terraform-vault-proxy.log

nohup vault proxy -config=/root/terraform-vault-proxy.hcl > /root/terraform-vault-proxy.log 2>&1 &

for i in $(seq 1 30); do
  if [ -s /root/terraform-proxy-token ] && curl -s http://127.0.0.1:8100/v1/sys/health >/dev/null 2>&1; then
    echo "Vault Proxy ready"
    break
  fi
  sleep 1
done

tail -20 /root/terraform-vault-proxy.log
```

如果日志里没有报错，且 `/root/terraform-proxy-token` 已经存在，说明 Proxy 已经用 AppRole 登录成功。

## 3.3 同一份 Terraform 代码，长 apply 现在成功

现在进入 Operator 工作区。注意我们不改任何 `.tf` 文件，只把 Terraform Vault provider 的连接目标从 Vault Server 改成 Proxy listener，并把 token 换成 Proxy auto-auth 管理的那枚 token。

```bash
cd /root/terraform-vault-aws-ministack/operator-workspace

export VAULT_ADDR=http://127.0.0.1:8100
export VAULT_TOKEN="$(cat /root/terraform-proxy-token)"
export TERRAFORM_VAULT_SKIP_CHILD_TOKEN=true
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=1

terraform apply -auto-approve -var='apply_delay=150s'
terraform output
```

> `TERRAFORM_VAULT_SKIP_CHILD_TOKEN=true` 是走 Vault Proxy 时的必备一项。它对应 Terraform Vault provider 的 `skip_child_token` 配置项，注意前缀是 `TERRAFORM_VAULT_` 而不是 `VAULT_`：`VAULT_*` 系列由 Vault SDK 直接消费，而 provider 自己附加的开关用 `TERRAFORM_VAULT_*` 命名。Terraform Vault provider 默认会先调一次 `auth/token/create` 给自己派生一枚短命子 token，再用子 token 去读 secrets。这里有两个问题：第一，AppRole policy `terraform-operator-dynamic-aws` 故意只授权了 `${backend}/creds/${role}` 一条路径，没有 `auth/token/create`，子 token 派生会被 Vault 拒绝（`Code: 403 permission denied`）；第二，即便放开了 `auth/token/create`，子 token 拿回来的 AWS lease 会挂在子 token 名下，而 Proxy 的 cache 与续期只覆盖它自己 auto-auth 管理的那枚父 token 所拉的 lease，子 token 的 lease 反而绕过了 Proxy 的续期路径，长 apply 会和第二步一样失败。设了 `TERRAFORM_VAULT_SKIP_CHILD_TOKEN=true` 后，Terraform 就直接复用 Proxy auto-auth 写到 `/root/terraform-proxy-token` 的那枚 token，Proxy 才能把这次拉到的 AWS lease 纳入缓存并在后台续期。

这次应当成功。背后发生的是：Terraform 仍然读取同一条 Vault AWS `creds` 路径；但这次请求经过 Proxy，Proxy 发现它是「由自己管理的 token 创建出来的 leased secret」，于是把响应纳入缓存并在后台续期。150 秒后，AWS provider 再调用 EC2 API 时，那名动态 IAM user 仍然存在。

旁证一下：

```bash
awslocal iam list-users \
  --query "Users[?starts_with(UserName, 'vault-')].UserName" \
  --output table

awslocal ec2 describe-instances \
  --query "Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table
```

应看到 `vault-...` 动态 IAM user 与 `dynamic-aws-creds-operator-instance`。

## 3.4 清理本步创建的 instance

清理时可以继续走 Proxy，也可以切回直连 Vault。这里为了少等 150 秒，使用 `apply_delay=0s`：

```bash
terraform destroy -auto-approve -var='apply_delay=0s'
terraform state list || true
```

---

## ✅ 验收

- [ ] Terraform 文件没有改动
- [ ] `VAULT_ADDR` 改为 `http://127.0.0.1:8100`
- [ ] 设置了 `TERRAFORM_VAULT_SKIP_CHILD_TOKEN=true`，让 Terraform Vault provider 复用 Proxy 的 token
- [ ] `terraform apply -auto-approve -var='apply_delay=150s'` 成功
- [ ] MiniStack 中能看到动态 IAM user 与 EC2 instance
- [ ] `terraform destroy -auto-approve -var='apply_delay=0s'` 后 state 为空

下一步回到 Admin 工作区，把 role 里的 `ec2:*` 移除，验证权限收紧仍然集中在 Vault role 上。