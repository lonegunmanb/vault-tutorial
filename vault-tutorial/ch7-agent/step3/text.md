# 第三步：观察 KV 更新后的重新渲染

先记录当前渲染文件内容。

```bash
cat /root/agent-demo/app.env
```

现在更新同一条 KV v2 机密。文件模板 Agent 的 `static_secret_render_interval` 被设置为 `10s`，因此它会周期性重新读取这类没有 lease 的静态机密。

```bash
vault kv put secret/agent/app \
  username='agent-user' \
  password='rotated-password' \
  api_key='rotated-api-key'
```

用下面的循环等待渲染文件出现新值。正常情况下，十几秒内可以看到 `rotated-password`。

```bash
for i in $(seq 1 20); do
  if grep -q 'rotated-password' /root/agent-demo/app.env; then
    echo "rendered file refreshed"
    cat /root/agent-demo/app.env
    break
  fi
  echo "waiting for Agent template refresh..."
  sleep 2
done
```

查看 Agent 日志中与模板渲染有关的记录。

```bash
tail -50 /tmp/vault-agent-file.log
```

本步骤验证的是 Agent 模板的刷新语义，而不是静态 KV API 缓存。Agent 会重新读取 KV v2 并重新写入文件；如果目标是缓存静态 KV API 响应以减少转发请求，应使用 Vault Proxy 的 static secret caching。