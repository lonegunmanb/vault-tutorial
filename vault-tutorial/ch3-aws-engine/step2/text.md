# 第二步：`iam_user` —— 每次取凭据 = AWS 上多一个真 IAM User

这一步对应 3.3 §3.1 的核心实验：写一个 `iam_user` Role，反复 `vault
read aws/creds/<role>`，去 MiniStack 端验证**每次都真的多了一个 IAM
User**，最后 `vault lease revoke` 看 user 立即消失。

## 2.1 准备 IAM 策略文件

```bash
cat > /root/s3-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:*", "Resource": "*" }
  ]
}
EOF
```

> 这里用 `s3:*` 是为了演示方便。生产里要按最小权限切到具体 Bucket /
> Action。

## 2.2 写一个 `iam_user` 类型的 Role

```bash
vault write aws/roles/s3-app \
  credential_type=iam_user \
  policy_document=@/root/s3-policy.json

vault read aws/roles/s3-app
```

注意 `credential_type` 和 `policy_document` 是 Role 的"模板"——它们
**不会**真的去 AWS 创建任何东西。AWS 端的实际操作发生在下一步、应用
来取凭据时。

## 2.3 第一次取凭据：观察 Vault 真的去 AWS 建了 user

```bash
vault read aws/creds/s3-app
```

输出里 `lease_id` / `lease_duration` / `access_key` / `secret_key` /
`session_token=<nil>`——典型的 IAM User AK/SK 形态（没 session_token）。

接下来再 `vault read` 一次，把字段拆出来存到 shell 变量里，留给后续
步骤用：

```bash
CREDS=$(vault read -format=json aws/creds/s3-app)
LEASE1=$(echo "$CREDS" | jq -r .lease_id)
AK1=$(echo "$CREDS" | jq -r .data.access_key)
SK1=$(echo "$CREDS" | jq -r .data.secret_key)
echo "lease=$LEASE1"
echo "AK=$AK1"
```

> ⚠️ **提醒**：上面是**两次独立的** `vault read aws/creds/s3-app`——
> 第一次给你看人类可读输出，第二次拿 JSON 拆字段。**每一次 read 都
> 是一次完整的"AWS 上建一个新 user"**——所以这一步结束时 IAM 上有
> **2 个 user**，而不是 1 个。这正好是下一节要演示的"每次取都是新
> user"行为，提前在这里见识一下。

去 MiniStack 端确认 IAM User 真的存在：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '.Users[] | {UserName, CreateDate}'
```

会看到**两个**名字像 `vault-token-s3-app-<unix_time>-<random>` 的
user——这就是 §5.2 里讲的 `username_template` 默认渲染结果。两个
`<unix_time>` 之间相差几秒，正好就是你执行那两条 `vault read` 的间隔。

## 2.4 第二次、第三次取——每次都是新 user

```bash
for i in 1 2; do
  vault read aws/creds/s3-app | grep access_key
done

aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '[.Users[] | .UserName] | length'
```

IAM User 数量应该是 4（§2.3 留下的 2 个 + 这一节 `for` 循环里 read
两次又新建的 2 个）。**这就是"每次取都是全新凭据"的字面意义——不复
用、不共享。**

## 2.5 用 Vault 颁发的凭据真的去调 AWS

把第一次拿到的 AK/SK 切进环境变量，再调 MiniStack 上的 S3：

```bash
AWS_ACCESS_KEY_ID=$AK1 AWS_SECRET_ACCESS_KEY=$SK1 \
  aws --endpoint-url=http://127.0.0.1:4566 s3 mb s3://vault-issued-bucket-$$
AWS_ACCESS_KEY_ID=$AK1 AWS_SECRET_ACCESS_KEY=$SK1 \
  aws --endpoint-url=http://127.0.0.1:4566 s3 ls
```

`make_bucket: vault-issued-bucket-...` 表示这把临时 AK/SK 在 MiniStack
的 S3 上**真的有 `s3:*` 权限**——和我们 Role 上 `policy_document` 一
致。

## 2.6 `vault lease revoke`：看 IAM User 立即消失

```bash
echo "=== revoke 前 IAM User 数量 ==="
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '[.Users[] | .UserName] | length'

echo ""
echo "=== revoke 第一次拿到的 lease ==="
vault lease revoke "$LEASE1"

echo ""
echo "=== revoke 后 IAM User 数量 ==="
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '[.Users[] | .UserName] | length'
```

数量减一——Vault 在 revoke 时反过来调了 `DeleteAccessKey` +
`DeleteUserPolicy` + `DeleteUser`，AWS 上对应的 user 已经不在了。

被 revoke 的那把 AK/SK 自然也失效了：

```bash
AWS_ACCESS_KEY_ID=$AK1 AWS_SECRET_ACCESS_KEY=$SK1 \
  aws --endpoint-url=http://127.0.0.1:4566 s3 ls 2>&1 | tail -2
```

返回 `InvalidClientTokenId` 之类错误——AK/SK 已经被 AWS 这一侧删掉了。

## 2.7 一次性把剩下的 lease 都 revoke 掉

```bash
vault lease revoke -prefix aws/creds/s3-app
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '[.Users[] | .UserName] | length'
```

`-prefix` 模式批量 revoke 所有匹配前缀的 lease——IAM User 数量回到 0。
**这就是"动态机密 = 凭据生命周期 ≡ Lease 生命周期"的字面含义**。

---

> 接下来一步换 `assumed_role` 类型，看 Vault 怎么用 STS 替你拿临时
> session（含 `session_token` 三件套）。
