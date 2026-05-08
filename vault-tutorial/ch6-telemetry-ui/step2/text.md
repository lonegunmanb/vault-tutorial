# 第二步：为待命节点开启 `unauthenticated_metrics_access`

正文 §4 强调，`listener` 子块中的 `telemetry { unauthenticated_metrics_access = true }` 是**唯一**能让待命节点就地返回自身指标、并免除 token 依赖的开关。本步把它加到上一步选中的 `STANDBY_PORT` 节点上，并通过 SIGHUP 触发配置热重载，观察行为转变。

## 2.1 找出 standby 对应的节点编号与配置文件

> Killercoda 的点击运行代码块不一定能继承上一步点过的环境变量。为安全起见，本步开头先重新加载 `$VAULT_TOKEN` 与 `$UNSEAL_KEY`、并重新推出 `LEADER_PORT` / `STANDBY_PORT`。

```bash
source /etc/profile.d/vault.sh

LEADER_PORT=$(/root/find-leader.sh)
for p in 8200 8210 8220; do
  if [ "$p" != "$LEADER_PORT" ]; then
    STANDBY_PORT=$p
    break
  fi
done
echo "leader = ${LEADER_PORT}, standby = ${STANDBY_PORT}"

# 端口 → 节点编号的映射
case "$STANDBY_PORT" in
  8200) STANDBY_N=1 ;;
  8210) STANDBY_N=2 ;;
  8220) STANDBY_N=3 ;;
esac
echo "目标 standby 节点：node-${STANDBY_N}（端口 ${STANDBY_PORT}）"
echo "配置文件：/root/vault-${STANDBY_N}.hcl"
```

## 2.2 修改配置：在 listener 块内追加 telemetry 子块

直接用 `sed` 把 `tls_disable = true` 这一行替换为追加了 telemetry 子块的形式：

```bash
sed -i "s|tls_disable     = true|tls_disable     = true\n\n  telemetry {\n    unauthenticated_metrics_access = true\n  }|" \
  /root/vault-${STANDBY_N}.hcl

# 检查改动
grep -A 6 'listener "tcp"' /root/vault-${STANDBY_N}.hcl
```

预期看到的 listener 块形如：

```hcl
listener "tcp" {
  address         = "0.0.0.0:8210"
  cluster_address = "127.0.0.1:8211"
  tls_disable     = true

  telemetry {
    unauthenticated_metrics_access = true
  }
}
```

## 2.3 重启该节点让新的 listener.telemetry 生效

> 严格说 `unauthenticated_metrics_access` 也可以通过 SIGHUP 热重载，但实际上这一跳转在不同版本上表现不一致（例如 1.19 上经常看到 SIGHUP 后仍返回 `307`）。为了课堂可靠复现，这里直接重启该节点。Raft 集群在三节点中踢掉一个 follower 只会导致短暂的头数不足，重启后重新 unseal 即可。

```bash
PID=$(cat /tmp/vault-${STANDBY_N}.pid 2>/dev/null)
[ -n "$PID" ] && kill "$PID"
sleep 2

/root/start-node.sh ${STANDBY_N}
sleep 3

# 重新 unseal。这里直接从 init-output.json 读 key，以免子 shell 丢失环境变量。
VAULT_ADDR="http://127.0.0.1:${STANDBY_PORT}" \
  vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)"

sleep 2
tail -n 5 /var/log/vault-${STANDBY_N}.log
```

预期看到该节点重新以 `HA mode: standby` 运行、不出现 panic / fatal。

## 2.4 验证：standby 现在就地返回指标且不需要 token

```bash
echo "=== 不带 token 直接抓 standby ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/sys/metrics"

echo "=== 取前 5 行确认是 Prometheus 文本格式 ==="
curl -sS \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/sys/metrics" | head -n 5
```

预期：第一段返回 `HTTP 200`（对比第一步中相同请求曾经返回 `307`）；第二段输出 `# HELP ...` 开头的 Prometheus 文本。

## 2.5 与未改造的另一台 standby 形成对比

任挑余下那台仍旧未开启未授权访问的 standby（如有），重复同样的不带 token 请求，应当仍旧得到 `307` 重定向，从而验证开关的作用范围确实是"逐 listener"的。

```bash
for p in 8200 8210 8220; do
  if [ "$p" != "$LEADER_PORT" ] && [ "$p" != "$STANDBY_PORT" ]; then
    OTHER_STANDBY=$p
    break
  fi
done

if [ -n "$OTHER_STANDBY" ]; then
  echo "=== 另一台未改造 standby (${OTHER_STANDBY})：仍是 307 ==="
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
    -H "Accept: prometheus/telemetry" \
    "http://127.0.0.1:${OTHER_STANDBY}/v1/sys/metrics"
fi
```

## 2.6 这一步的核心闭环

`listener.telemetry.unauthenticated_metrics_access` 的两项行为转变都被复现：免除 token 鉴权、由"重定向到 leader"变为"就地返回自身指标"。下一步把目光收回 leader 节点的顶层 `telemetry` 块，演示 `prefix_filter`。
