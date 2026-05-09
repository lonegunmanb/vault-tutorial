# 第三步：观察请求头保护与缓存清理 API

第二个 Proxy 的 listener 启用了 `require_request_header = true`。先用 `curl` 不带请求头访问 Proxy，可以看到 Proxy 在请求到达 Vault 前就返回 412。

```bash
curl -s -i http://127.0.0.1:8101/v1/sys/health | head -12
```

再加上 `X-Vault-Request: true` 请求头，Proxy 才会接受请求并转发给 Vault。

```bash
curl -s -i \
  -H "X-Vault-Request: true" \
  http://127.0.0.1:8101/v1/sys/health | head -12
```

本实验配置了空的 `cache {}` block，因此 Proxy 的 cache 子系统已经启用；但请注意，空 `cache {}` 并不表示所有 KV 读取都会被自动缓存。这里调用 `/proxy/v1/cache-clear`，目的是体验 Proxy 自身的 cache 管理 API。

```bash
cat > /tmp/cache-clear.json <<'EOF'
{
  "type": "all"
}
EOF

curl -s -i \
  -H "X-Vault-Request: true" \
  --request POST \
  --data @/tmp/cache-clear.json \
  http://127.0.0.1:8101/proxy/v1/cache-clear | head -12
```

如果看到 `HTTP/1.1 200 OK`，说明 cache-clear API 调用成功。即使当时没有可清理的缓存条目，该 API 也可以返回成功。

查看 Proxy 日志，把认证、代理转发和缓存相关信息分开观察。

```bash
grep -E 'authentication successful|token written|received request|forwarding request|stripping|proxy.cache|cache' /tmp/proxy-force.log | tail -80
```

这一阶段的关键点是：412 通常表示 Proxy listener 的请求头保护拒绝了请求；403 通常表示 Vault 根据最终 token 的 policy 拒绝了请求；cache-clear 是 Proxy 管理 API，不能把它误解为“证明所有 KV 请求都会缓存”。