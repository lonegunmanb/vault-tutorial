# 第一步：创建针对 `transit` 引擎的速率限流并触发被拒响应

## 1.1 启动并初始化 Vault

```bash
./start-vault.sh
sleep 3

vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh

vault operator unseal "$UNSEAL_KEY"
```

## 1.2 启用 file 审计设备

正文 9.1 第 2.4 段提示"立刻启用至少一台审计设备"是基线项之一；同时本实验稍后会用到 file 审计日志去观察被拒请求是否进入审计：

```bash
vault audit enable file file_path=/var/log/vault_audit.log
```

## 1.3 启用 transit 引擎并创建一把测试密钥

```bash
vault secrets enable transit
vault write -f transit/keys/orders
```

## 1.4 创建一条针对 `transit` 引擎的速率限流配额

把 transit 引擎整体限到"每秒 3 个请求"——这是一个课堂友好的极小阈值，便于在 `for` 循环里几秒钟之内就触发被拒：

```bash
vault write sys/quotas/rate-limit/transit-limit \
  path="transit" \
  rate=3 \
  interval=1
```

读取该规则验证生效：

```bash
vault read sys/quotas/rate-limit/transit-limit
```

预期输出会显示 `path: transit/`、`rate: 3`、`interval: 1`、`group_by: ip`、`type: rate-limit`。

## 1.5 用 `for` 循环把加密请求量打到阈值之上

每秒打 10 个加密请求，远超 `rate=3` 的限制；记录每次请求的 HTTP 状态码：

```bash
B64=$(echo -n 'hello' | base64)

for i in $(seq 1 10); do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -X POST \
    -d "{\"plaintext\":\"${B64}\"}" \
    http://127.0.0.1:8200/v1/transit/encrypt/orders)
  echo "请求 ${i}: HTTP ${CODE}"
done
```

预期：前 3 次返回 `HTTP 200`，从第 4 次起开始出现 `HTTP 429`（"Too Many Requests"）——这就是正文 9.1 第 4.1 段所讲的"窗口内第 N+1 个请求被立即拒收"现象。

## 1.6 这一步的核心闭环

一条针对 `transit` 引擎的速率限流配额（`rate=3, interval=1`）已生效；学员已在终端里观察到"窗口内超出阈值的请求被立即以 HTTP 429 拒绝"这一关键现象。下一步将通过审计日志观察这些被拒请求**默认是否被记录**。
