# 第四步：用 cache-clear 驱逐租约，并验证静态 KV 不会被缓存

本步分两段：先用教程第 6 节讲过的 `/agent/v1/cache-clear` 端点把 Step 3 缓存下来的那份 lease 清掉、再次申请观察 LocalStack 一侧多出新 IAM User；然后通过 Agent 连续两次读 KV 静态机密，结合 Vault 审计日志确认两次都被转发到了 Vault Server——印证『Agent 缓存不覆盖 KV』这条边界。

## 4.1 用 type=lease 驱逐 Step 3 缓存下来的那份租约

先把 Step 3 拿到的 `lease_id` 取出来：

```bash
LEASE_ID=$(jq -r '.lease_id' /tmp/creds-1.json)
echo "$LEASE_ID"
```

然后构造 cache-clear payload，按教程第 6 节的官方示例写法：

```bash
cat > /tmp/cache-clear.json <<EOF
{
  "type": "lease",
  "value": "$LEASE_ID"
}
EOF
cat /tmp/cache-clear.json
```

向 Agent 的 cache-clear 端点 POST：

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  --request POST --data @/tmp/cache-clear.json \
  http://127.0.0.1:8100/agent/v1/cache-clear
```

应当输出 `HTTP 200`。

## 4.2 再次申请同一份动态凭据：缓存已清，必须重新落到 Vault

```bash
curl -s --request GET http://127.0.0.1:8100/v1/aws/creds/dev-iam \
  | tee /tmp/creds-3.json | jq '{lease_id, data: .data | {access_key}}'
```

对比 `/tmp/creds-1.json`：

```bash
diff <(jq -r .lease_id /tmp/creds-1.json) <(jq -r .lease_id /tmp/creds-3.json) \
  && echo "lease_id 相同（不应出现）" \
  || echo "lease_id 不同：缓存确实被清除，第三次重新落到了 Vault"
```

应当看到 `lease_id 不同`。

到 LocalStack 一侧再数一次 IAM User：

```bash
aws --endpoint-url=http://127.0.0.1:4566 iam list-users | jq '.Users | length'
```

应当输出 `2`——第三次申请确实让 LocalStack 多创建了一个 IAM User，这是缓存被驱逐后『回源到 Vault』的硬证据。

> 教程第 6 节列出的 `cache-clear` 合法 `type` 值有 `request_path` / `lease` / `token` / `token_accessor` / `all` 五种。本步用的是 `lease`，按 lease ID 精确驱逐；如果想清空整个 Agent 缓存，可以把 payload 改成 `{"type":"all"}`（`type=all` 时 `value` 字段可以省略）。

## 4.3 验证静态 KV 不会被 Agent 缓存

教程第 2 节末尾那条边界这次要在终端里亲眼看一遍。先记下当前审计日志里 `secret/data/agent/static` 的命中条数：

```bash
BEFORE=$(grep -c '"path":"secret/data/agent/static"' /root/vault-audit.log)
echo "before=$BEFORE"
```

通过 Agent listener 连续两次读 KV：

```bash
for i in 1 2; do
  curl -s --request GET http://127.0.0.1:8100/v1/secret/data/agent/static \
    | jq '{request: '"$i"', username: .data.data.username, password: .data.data.password}'
done
```

两次输出应当完全相同（数据本身没变），但**关键看审计日志的差值**：

```bash
AFTER=$(grep -c '"path":"secret/data/agent/static"' /root/vault-audit.log)
echo "after=$AFTER"
echo "新增 = $((AFTER-BEFORE))"
```

应当看到 `新增 = 4`——即两次读各产生 1 条 request + 1 条 response 共 2 条审计记录，两次合计 4 条。

> 这是 Agent 缓存边界的硬证据：**两次完全相同的 KV 读请求都被转发到了 Vault Server**，Agent 没有把第二次响应从内存里直接返回。如果同样的对照换成 Step 3 的 `aws/creds/dev-iam`，会看到第二次完全没有新增审计记录——这就是『带 lease 的机密被缓存、KV 不被缓存』的本质对比。

> 如果业务的真实痛点是『同一个 KV 路径每秒被读上千次』，应当按教程第 2 节给出的选型表换用 [Vault Proxy 的 static secret caching](/ch5-vault-proxy)；本节的 Agent 缓存对它无能为力。

## 4.4 收尾（可选）：观察 Agent 缓存对绕过自身的撤销操作不感知

教程第 3 节提到一种『陈旧条目』情况——客户端绕过 Agent 直接向 Vault Server 撤销 lease 时，Agent 不知道这次撤销发生过。可以快速复现一次：

```bash
# 先经 Agent 申请一份新凭据，让它进缓存
LEASE_NEW=$(curl -s --request GET http://127.0.0.1:8100/v1/aws/creds/dev-iam | jq -r '.lease_id')
echo "new lease: $LEASE_NEW"

# 直接打 Vault Server（绕过 Agent）撤销它
VAULT_TOKEN=root vault lease revoke "$LEASE_NEW"

# 再次通过 Agent 拿同一个端点：因为 Agent 缓存里那条仍在，会把已撤销的旧响应直接返回给你
curl -s --request GET http://127.0.0.1:8100/v1/aws/creds/dev-iam | jq -r '.lease_id'
```

输出的 `lease_id` 与刚刚被撤销的 `$LEASE_NEW` **相同**——这就是教程里说的『陈旧条目』。要清掉它，按 4.1 的方法用 `cache-clear` 显式驱逐即可。

## 4.5 这一步的核心闭环

学员在终端里完整看到了：
- Agent 缓存的精确驱逐入口（`/agent/v1/cache-clear`，按 `type=lease` + `value=<lease_id>` 精确命中）；
- KV 静态机密**不**被 Agent 缓存覆盖（审计日志计数为证）；
- Agent 对『绕过自身的撤销』天然不感知，需要靠 `cache-clear` 手工治理陈旧条目。

到这里，本节配套教程第 1~6 节的所有概念都已经在终端里被亲手验证过一遍。
