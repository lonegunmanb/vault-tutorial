# 第三步：追加一条全局速率限流规则作为集群兜底

正文 9.1 第 4.3 段"用法一：全集群每秒 100 个请求"以及 4.4 段"何时该用速率限流——所有部署都建议至少配一条 `path=""` 的全局规则"中已说明：把 `path` 留空即得到一条对集群所有请求生效的全局规则。本步亲手创建一条全局规则、并验证它对**与 transit 无关的请求**也会生效。

## 3.1 删除上一步的 `transit-limit`（避免与全局规则混淆视听）

```bash
vault delete sys/quotas/rate-limit/transit-limit
vault list sys/quotas/rate-limit
```

预期：第一条命令输出 `Success! Data deleted (if it existed) at: sys/quotas/rate-limit/transit-limit`；第二条命令输出 `No value found at sys/quotas/rate-limit`——这是 Vault 在该路径下"已经一条规则都不剩"时的标准提示，并非错误（`vault list` 在结果集为空时统一以此种形式回复，而不是返回一个空列表）。

## 3.2 创建一条全局速率限流：`rate=5, interval=1`

```bash
vault write sys/quotas/rate-limit/global-rate rate=5
vault read sys/quotas/rate-limit/global-rate
```

预期输出 `path: n/a`、`rate: 5`、`interval: 1`、`group_by: ip`、`type: rate-limit`——这与正文中给出的输出示例字段完全一致。

## 3.3 用一个**与 transit 无关**的端点触发被拒

故意不打 transit；改去打一个最普通的健康检查/系统端点（每秒 15 次，远超 5）：

```bash
for i in $(seq 1 15); do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    http://127.0.0.1:8200/v1/sys/mounts)
  echo "请求 ${i}: HTTP ${CODE}"
done
```

预期：前 5 次返回 `200`，从第 6 次起出现 `429`。这证明 `path` 留空的全局规则对**所有挂载点的所有路径**都生效，并不局限于某个具体引擎。

## 3.4 （可选）观察响应头里的剩余配额信息

正文 4.2 段提到 `enable_rate_limit_response_headers` 可用于把当前剩余配额信息塞到 HTTP 响应头中。打开它再次发起一个请求并打印响应头：

```bash
vault write sys/quotas/config enable_rate_limit_response_headers=true

curl -sS -D - -o /dev/null \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  http://127.0.0.1:8200/v1/sys/mounts | grep -i "ratelimit\|retry"
```

预期：响应头中出现以 `X-Ratelimit-` 开头的若干字段；超出阈值后还会出现 `Retry-After` 提示客户端何时再试。这是给客户端做"自适应退避"的唯一标准信号源。

## 3.5 收尾：把开关还原

```bash
vault write sys/quotas/config enable_rate_limit_response_headers=false
```

## 3.6 这一步的核心闭环

学员已亲手把"全集群兜底"这条最重要的速率限流规则配置到位、并通过一个与具体引擎无关的端点验证了它的覆盖面，最后还体验了响应头机制如何让客户端做出自适应退避。
