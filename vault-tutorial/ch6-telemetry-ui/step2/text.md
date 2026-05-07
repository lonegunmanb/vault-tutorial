# 第二步：为待命节点开启 `unauthenticated_metrics_access`

正文 §4 强调，`listener` 子块中的 `telemetry { unauthenticated_metrics_access = true }` 是**唯一**能让待命节点就地返回自身指标、并免除 token 依赖的开关。本步把它加到上一步选中的 `STANDBY_PORT` 节点上，并通过 SIGHUP 触发配置热重载，观察行为转变。

## 2.1 找出 standby 对应的节点编号与配置文件

```bash
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

## 2.3 SIGHUP 触发配置热重载

Vault 对 listener 相关配置变更支持通过 SIGHUP 热重载：

```bash
PID=$(cat /tmp/vault-${STANDBY_N}.pid)
kill -HUP "$PID"
sleep 1

# 看一眼日志确认 reload 成功
tail -n 5 /var/log/vault-${STANDBY_N}.log
```

预期日志中出现类似 `core: reloaded ...` 或 `received SIGHUP` 的行；不应出现 panic / fatal。

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
