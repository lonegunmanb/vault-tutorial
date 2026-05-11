# 第三步：连续两次申请 AWS 动态凭据，亲眼看到第二次走的是 Agent 缓存

教程第 2 节给出的两条规则中第 2 条是：**用 Agent 已管着的 Token 通过 Agent 发起的『新建带租约机密』请求，会被缓存**。`aws/creds/dev-iam` 正是这种『带租约机密』。本步把同一个请求通过 Agent listener 打两次，对比响应中的 `lease_id` / `access_key`，并到 LocalStack 一侧数 IAM User 的真实数量。

## 3.1 第一次申请：经 Agent 走到 Vault，再走到 LocalStack

```bash
curl -s --request GET http://127.0.0.1:8100/v1/aws/creds/dev-iam \
  | tee /tmp/creds-1.json | jq '{lease_id, lease_duration, data: .data | {access_key}}'
```

应当看到：

- `lease_id` 形如 `aws/creds/dev-iam/abc123...`；
- `lease_duration` 大约 600（即 10 分钟，对应 Step 1 配的默认 lease）；
- `data.access_key` 是一段 `AKIA...` 形式的字符串。

> 注意 `curl` 没有带 `X-Vault-Token` 头——这正是 `cache.use_auto_auth_token = true` 的作用：Agent 替无 token 的客户端贴上了它通过 Auto-auth 拿到的 token，再把请求转发给 Vault；Vault 调 LocalStack 的 IAM API 真创建了一个 IAM User 并返回带 lease 的响应；Agent 把这份响应缓存了下来。

到 LocalStack 一侧数一下 IAM User：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '.Users | map({UserName, CreateDate}) | length as $n | {count: $n, items: .}'
```

应当看到 `count: 1`，并且唯一这个 User 的 `UserName` 形如 `vault-token-...`。

## 3.2 第二次申请：完全相同的请求，观察是否走缓存

```bash
curl -s --request GET http://127.0.0.1:8100/v1/aws/creds/dev-iam \
  | tee /tmp/creds-2.json | jq '{lease_id, lease_duration, data: .data | {access_key}}'
```

请仔细对比两次输出：

- `lease_id` 应当**完全相同**；
- `data.access_key` 应当**完全相同**。

为了不靠肉眼，可直接做差：

```bash
diff <(jq -S . /tmp/creds-1.json) <(jq -S . /tmp/creds-2.json) && echo "两次响应完全一致：缓存命中"
```

输出 `两次响应完全一致：缓存命中`。

## 3.3 用 LocalStack 一侧的『真实 IAM User 数量』做交叉验证

如果第二次请求真的命中了 Agent 缓存、没有打到 Vault Server，那么 LocalStack 一侧 IAM User 的数量就**应该还是 1**：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam list-users \
  | jq '.Users | length'
```

应当输出 `1`。

> 这一行数字是本实验最有说服力的一处证据：我们没办法直接在客户端看到『请求停在了 Agent 内存里』，但 LocalStack 这端的真实状态变化骗不了人——第一次创建了 1 个 IAM User，第二次没有新增，说明第二次确实没有走到 Vault Server。

## 3.4 用 Vault 审计日志再交叉验证一次

第 1 步的 background 已经启用了 file 审计设备，路径 `/root/vault-audit.log`：

```bash
grep -c '"path":"aws/creds/dev-iam"' /root/vault-audit.log
```

应当输出 `2`（一次 request、一次 response，都是第一次申请时记录的；第二次没到 Vault 所以审计日志里**不会**多出新的 `aws/creds/dev-iam` 条目）。

> Vault 的 file 审计设备会把『每一次到达 Vault Server 的请求』完整记录下来；缓存命中没到 Vault Server，自然也就没有新条目。这是与 LocalStack 一侧数据互相印证的第二条证据线。

## 3.5 这一步的核心闭环

同一个客户端连续两次问 Agent 要同一份动态 IAM 凭据：第一次落到 Vault → LocalStack 真创建 IAM User → Agent 缓存响应；第二次直接命中 Agent 内存里的缓存条目，LocalStack 不再多 IAM User，Vault 审计日志里也不再增加 `aws/creds/dev-iam` 记录。这就是『Agent 缓存为 Vault 集群降压』在生产里的真实形态。
