# 第三步：`assumed_role` —— 让 Vault 替你 AssumeRole 拿 STS 三件套

3.3 §3.2 的核心要点：`assumed_role` **不**会在 AWS 上建新的 IAM User，
而是调 `sts:AssumeRole` 进入一个**预先存在**的 IAM Role。所以：

- 凭据带 `session_token`（STS 三件套：AK + SK + session_token）
- 必须先在 AWS 上手动把目标 Role 建好、并把 Vault 的 root user 加到
  Role 的信任策略里
- 取凭据走 `aws/sts/<role>`，**不是** `aws/creds/<role>`

## 3.1 在 MiniStack 上手动建一个目标 IAM Role

先写一份"任何 IAM 实体都能 AssumeRole"的信任策略——生产里要换成更窄
的 `Principal`：

```bash
cat > /root/trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "*" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws --endpoint-url=http://127.0.0.1:4566 iam create-role \
  --role-name vault-target-role \
  --assume-role-policy-document file:///root/trust.json \
  | jq '.Role | {RoleName, Arn}'
```

记下 ARN：`arn:aws:iam::000000000000:role/vault-target-role`。

再把 §2.1 的 S3 策略**直接挂**到这个 Role 上（`assumed_role` 拿到的
权限来自目标 Role 自身，不像 `iam_user` 是 Vault 现挂的）：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam put-role-policy \
  --role-name vault-target-role \
  --policy-name s3-access \
  --policy-document file:///root/s3-policy.json
```

## 3.2 在 Vault 里写 `assumed_role` 类型的 Role

```bash
vault write aws/roles/s3-assume \
  credential_type=assumed_role \
  role_arns=arn:aws:iam::000000000000:role/vault-target-role

vault read aws/roles/s3-assume
```

`role_arns` 是一组**已存在**的目标 Role ARN，请求时可以用 `-role_arn=`
覆盖选其中一个。

## 3.3 取凭据：习惯上走 `sts/`

先把两条路径都打一下，对比看效果：

```bash
echo "=== 走 creds/ ==="
vault read aws/creds/s3-assume

echo ""
echo "=== 走 sts/ ==="
vault read aws/sts/s3-assume
```

你会发现**两条都成功**，而且都返回了 `session_token`——这是现代 Vault
（0.11.6+）的实际行为：`creds/` 和 `sts/` 都会路由到这个 Role，最终
**返回什么样的凭据由 `credential_type` 决定**，不由路径决定。所以
`assumed_role` 走哪条都是 STS 三件套。

那为什么官方文档让你走 `sts/`？历史包袱 + 阅读约定：

- 老版本 Vault 里 `sts/` 才支持 `assumed_role` / `federation_token`，
  `creds/` 仅给 `iam_user`，文档至今保留这个写法
- 团队约定「`sts/` = STS 三件套，`creds/` = 长期 IAM User AK/SK」
  能让 Code Review 一眼看出意图

> 输出和 §2.3（`iam_user`）相比，最明显的差别是**多出来的
> `session_token` 字段**——这就是 STS 三件套的标志。

## 3.4 用 STS 三件套真的去 MiniStack 调 S3

注意必须**同时**带上 `AWS_SESSION_TOKEN`：

```bash
CREDS=$(vault read -format=json aws/sts/s3-assume)
AK=$(echo "$CREDS" | jq -r .data.access_key)
SK=$(echo "$CREDS" | jq -r .data.secret_key)
ST=$(echo "$CREDS" | jq -r .data.session_token)
echo "AK=$AK"
echo "session_token (前 30 字符) = ${ST:0:30}..."

AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws --endpoint-url=http://127.0.0.1:4566 s3 ls
```

成功列出 §2.5 创建的那个 bucket——证明 `assumed_role` 拿到的 session
权限来自 `vault-target-role` 上的 `s3-access` 内联策略。

## 3.5 验证：AWS 端**没有**新增 IAM User

这是 `assumed_role` 与 `iam_user` 最直观的区别：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '[.Users[] | .UserName] | length'
```

应该是 0（§2.7 已经清空过）——`assumed_role` 不建 user，所以 IAM 里
看不到任何变化，**全部状态都在 STS 那边的 session 里**，session 到期
自动失效。

## 3.6 `default_sts_ttl` —— STS 的特殊 lease 字段

```bash
vault write aws/roles/s3-assume \
  credential_type=assumed_role \
  role_arns=arn:aws:iam::000000000000:role/vault-target-role \
  default_sts_ttl=15m \
  max_sts_ttl=1h
```

注意 §3.3 §5.3 的提醒：

- `iam_user` 的寿命由 `aws/config/lease` + Role 的
  `default_lease_ttl` 决定——和 STS 字段无关
- `assumed_role` / `federation_token` 的寿命由 `default_sts_ttl` /
  `max_sts_ttl` 决定（直接传给 STS 的 `DurationSeconds`）

如果你 `vault write aws/roles/s3-assume default_lease_ttl=10m` 配在
`assumed_role` 上，**不会**生效——STS session 的寿命由 AWS 自己控制，
Vault 只是个搬运工。

---

> 最后一步：把 Policy 写到刚刚好——按 Role 名精确控制谁能取哪条凭据。
