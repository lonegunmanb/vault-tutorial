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

## 3.3 重启 leader 让新过滤器生效并复测

> 严格说顶层 `telemetry` 块里的 `prefix_filter` / `filter_default` 在文档上是支持 SIGHUP 热重载的，但实际上 go-metrics 的 sink/filter 在进程启动时一次性构建，1.19 上常见 SIGHUP 之后过滤器并没有真正生效（`BEFORE==AFTER`）。这里直接硬重启原 leader 节点，再让集群重新选主。

```bash
OLD_LEADER_N=${LEADER_N}
PID=$(cat /tmp/vault-${OLD_LEADER_N}.pid)
kill "$PID"
sleep 2

/root/start-node.sh ${OLD_LEADER_N}
sleep 3

# 重新 unseal 这台被重启的节点（它回来后可能是 leader 也可能是 standby，先 unseal 再说）
VAULT_ADDR="http://127.0.0.1:${LEADER_PORT}" \
  vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)"
sleep 3

# 杀掉旧 leader 后集群通常会换主，重新发现当前 leader 端口
LEADER_PORT=$(./find-leader.sh)
echo "new leader = ${LEADER_PORT}"
```

如果新选出来的 leader 不是刚才改过配置的那台，本节实验就失去对照意义——为简化课堂演示，这里直接 step-down 一次，强制把领导权交回到我们改过 `prefix_filter` 的那个节点上：

```bash
case "$LEADER_PORT" in
  8200) CUR_N=1 ;;
  8210) CUR_N=2 ;;
  8220) CUR_N=3 ;;
esac

if [ "$CUR_N" != "$OLD_LEADER_N" ]; then
  echo "当前 leader=node-${CUR_N}，与改过配置的 node-${OLD_LEADER_N} 不一致，执行 step-down 让位"
  vault operator step-down
  sleep 3
  LEADER_PORT=$(./find-leader.sh)
  echo "step-down 后 leader = ${LEADER_PORT}"
fi

LEADER_N=${OLD_LEADER_N}
```

现在再统计一次：

```bash
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

正文提到，过滤规则之间出现重叠时以"更具体"的规则为准，且屏蔽优先于放行。在 `prefix_filter` 中追加一个更具体的正向规则，并同样通过"重启 + 必要时 step-down"让其生效：

```bash
sed -i 's|prefix_filter             = \["-vault.expire"\]|prefix_filter             = ["-vault.expire", "+vault.expire.num_leases"]|' \
  /root/vault-${LEADER_N}.hcl

PID=$(cat /tmp/vault-${LEADER_N}.pid)
kill "$PID"
sleep 2

/root/start-node.sh ${LEADER_N}
sleep 3

VAULT_ADDR="http://127.0.0.1:$((8200 + (LEADER_N-1)*10))" \
  vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)"
sleep 3

LEADER_PORT=$(./find-leader.sh)
case "$LEADER_PORT" in
  8200) CUR_N=1 ;; 8210) CUR_N=2 ;; 8220) CUR_N=3 ;;
esac
if [ "$CUR_N" != "$LEADER_N" ]; then
  vault operator step-down
  sleep 3
  LEADER_PORT=$(./find-leader.sh)
fi
echo "leader = ${LEADER_PORT}"

curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" \
  | grep -E '^vault_expire_num_leases'
```

预期：`vault_expire_num_leases` 这一条指标被放行回来，而其它 `vault_expire_*` 指标仍然被屏蔽。

## 3.5 这一步的核心闭环

通过两次硬重启 + 同一个 grep 计数，正文中"`prefix_filter` 在指标暴露口径上做减法、且更具体的规则优先"两条规律都被复现。下一步开启 UI 并完成一次浏览器登录。
