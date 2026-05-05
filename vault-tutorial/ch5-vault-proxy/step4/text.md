# 第四步：缓存清理、日志与错误定位

本实验配置了空的 `cache {}` 块，因此 Proxy 的缓存子系统已启用。为了避免把静态 KV 缓存和企业级事件订阅混入基础实验，这里只调用缓存清理 API，确认 Proxy API 入口可用。

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
  http://127.0.0.1:8100/proxy/v1/cache-clear | head -12
```

查看 Proxy 日志，定位刚才的成功请求、412 请求和 403 请求。

```bash
tail -80 /tmp/vault-proxy.log
```

用下面的表格整理排错思路。

| 现象 | 常见原因 | 首要检查点 |
| :--- | :--- | :--- |
| Proxy 进程未启动 | 配置语法错误、端口占用、AppRole 文件缺失 | `/tmp/vault-proxy.log` |
| 返回 412 | listener 要求 `X-Vault-Request: true` | 请求头是否存在 |
| 返回 403 | Vault policy 拒绝最终 token | `VAULT_TOKEN=$(cat /root/proxy-token) vault token capabilities <path>` |
| 请求没有使用预期身份 | `use_auto_auth_token` 模式理解错误 | `api_proxy` 块是 `true` 还是 `"force"` |

最后停止 Proxy，避免后台进程继续占用端口。

```bash
kill "$(cat /tmp/vault-proxy.pid)"
```

这一阶段的关键点是：Proxy 相关问题要分层排查，先看 Proxy listener 是否接受请求，再看 Proxy 是否成功 Auto-auth，最后再看 Vault policy 是否允许最终 token 访问目标路径。
