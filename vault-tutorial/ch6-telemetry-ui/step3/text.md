# 第三步：用 `prefix_filter` 按前缀粗筛指标

正文 §2.1 介绍过 `filter_default` 与 `prefix_filter` 共同构成"按前缀粗筛"的第一道闸门。本步在 leader 节点上对比开启前后被屏蔽前缀的指标条数。

## 3.1 先记录改动前的基线

抓取一份 leader 当前的指标文本，统计带 `vault_expire` 前缀的条目数（注意：Prometheus 文本格式中 Vault 内部的 `.` 会被替换为 `_`，因此 `vault.expire` 在 Prometheus 输出中表现为 `vault_expire`）：

```bash
BEFORE=$(curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" \
  | grep -E '^vault_expire_' | wc -l)
echo "改动前 vault_expire_* 条目数：${BEFORE}"
```

## 3.2 修改 leader 配置：在顶层 telemetry 块追加 prefix_filter

定位 leader 节点编号并写入新的过滤规则：

```bash
case "$LEADER_PORT" in
  8200) LEADER_N=1 ;;
  8210) LEADER_N=2 ;;
  8220) LEADER_N=3 ;;
esac

# 把 disable_hostname = true 这一行替换为同时追加 filter_default 与 prefix_filter
sed -i 's|disable_hostname          = true|disable_hostname          = true\n  filter_default            = true\n  prefix_filter             = ["-vault.expire"]|' \
  /root/vault-${LEADER_N}.hcl

grep -A 5 'telemetry {' /root/vault-${LEADER_N}.hcl
```

预期看到的顶层 telemetry 块形如：

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
  filter_default            = true
  prefix_filter             = ["-vault.expire"]
}
```

含义：默认放行所有指标（`filter_default = true`），但显式屏蔽掉以 `vault.expire` 为前缀的全部指标。

## 3.3 SIGHUP 重载并复测

```bash
PID=$(cat /tmp/vault-${LEADER_N}.pid)
kill -HUP "$PID"
sleep 2

AFTER=$(curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" \
  | grep -E '^vault_expire_' | wc -l)

echo "改动前 vault_expire_* 条目数：${BEFORE}"
echo "改动后 vault_expire_* 条目数：${AFTER}"
```

预期：`AFTER` 显著小于 `BEFORE`（多数情况下降为 0）。这证明 `prefix_filter` 的负向规则确实在指标暴露阶段就把对应前缀彻底屏蔽掉了——这也是降低观测后端写入压力的最廉价手段。

## 3.4 反向验证：保留某一条具体子前缀

正文提到，过滤规则之间出现重叠时以"更具体"的规则为准，且屏蔽优先于放行。可以在 `prefix_filter` 中追加一个更具体的正向规则，例如：

```bash
sed -i 's|prefix_filter             = \["-vault.expire"\]|prefix_filter             = ["-vault.expire", "+vault.expire.num_leases"]|' \
  /root/vault-${LEADER_N}.hcl

PID=$(cat /tmp/vault-${LEADER_N}.pid)
kill -HUP "$PID"
sleep 2

curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" \
  | grep -E '^vault_expire_num_leases'
```

预期：`vault_expire_num_leases` 这一条指标被放行回来，而其它 `vault_expire_*` 指标仍然被屏蔽。

## 3.5 这一步的核心闭环

通过两次 SIGHUP 与同一个 grep 计数，正文中"`prefix_filter` 在指标暴露口径上做减法、且更具体的规则优先"两条规律都被复现。下一步开启 UI 并完成一次浏览器登录。
