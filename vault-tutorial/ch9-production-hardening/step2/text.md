# 第二步：对比 `enable_rate_limit_audit_logging` 开/关下的审计日志

承接上一步，`transit-limit` 配额已生效，file 审计设备也已启用。本步把视线移到审计日志上，对比同一份"被拒请求"在配置开关两端的可见性差异。

## 2.1 默认状态：被拒请求**不**进入审计日志

先查看当前配额配置：

```bash
vault read sys/quotas/config
```

预期输出中 `enable_rate_limit_audit_logging` 字段为 `false`——这是默认值。正文 9.1 第 4.2 段已说明：默认情况下被拒请求不会进入审计日志，目的是避免大流量异常时审计日志写入反过来拖垮 Vault。

清空旧审计日志，记下行数基线：

```bash
> /var/log/vault_audit.log
wc -l /var/log/vault_audit.log
```

再次触发被拒请求：

```bash
B64=$(echo -n 'hello' | base64)
for i in $(seq 1 10); do
  curl -sS -o /dev/null -w "请求 ${i}: HTTP %{http_code}\n" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -X POST \
    -d "{\"plaintext\":\"${B64}\"}" \
    http://127.0.0.1:8200/v1/transit/encrypt/orders
done
```

查看审计日志中**被拒请求（rate limit quota exceeded）相关条目**的数量：

```bash
grep -c "rate limit quota exceeded" /var/log/vault_audit.log
```

预期输出为 `0`。再确认一下日志里有正常的 `transit/encrypt/orders` 请求记录（即前 3 个成功的写入有被审计）：

```bash
grep -c "transit/encrypt/orders" /var/log/vault_audit.log
```

预期输出为大于 0（每条 request + 对应 response 各算一行；如果只关心成功被审计的那 3 次，可能看到 6 条）。

## 2.2 打开 `enable_rate_limit_audit_logging` 后再次复现

```bash
vault write sys/quotas/config enable_rate_limit_audit_logging=true
vault read sys/quotas/config
```

预期：`enable_rate_limit_audit_logging` 已经变为 `true`。

清空审计日志后再触发一次相同的循环：

```bash
> /var/log/vault_audit.log

B64=$(echo -n 'hello' | base64)
for i in $(seq 1 10); do
  curl -sS -o /dev/null -w "请求 ${i}: HTTP %{http_code}\n" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -X POST \
    -d "{\"plaintext\":\"${B64}\"}" \
    http://127.0.0.1:8200/v1/transit/encrypt/orders
done

grep -c "rate limit quota exceeded" /var/log/vault_audit.log
```

预期：上一条 grep 现在能匹配到大于 0 的条目数——本节正文中所讲的"开启后被拒请求进入审计"已被复现。

## 2.3 把开关还原到默认（推荐做法）

正文也提示：开启该开关在**异常大流量**期间可能反过来影响 Vault 性能。课堂结束前把它还原到默认：

```bash
vault write sys/quotas/config enable_rate_limit_audit_logging=false
```

## 2.4 这一步的核心闭环

`enable_rate_limit_audit_logging` 这个全局开关在两端的实际效果都已被亲眼观察到：默认关闭，被拒请求不进入审计日志；显式置 true 后，被拒请求才会被审计设备记录。下一步追加一条 `path` 留空的全局速率限流，验证它对所有请求生效（不限于 `transit/`）。
