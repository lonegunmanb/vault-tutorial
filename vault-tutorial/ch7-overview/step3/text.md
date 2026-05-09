# 第三步：方式三 —— Vault Proxy 代理请求

查看预置的 Proxy 配置文件。重点观察四块：`vault` 指向真实 Vault 服务地址、`auto_auth` 用 AppRole 登录、`api_proxy` 设为 `use_auto_auth_token = "force"` 强制使用 Proxy 的 Auto-auth token、`listener` 在 `127.0.0.1:8100` 接收请求并要求 `X-Vault-Request: true` 头。

```bash
sed -n '1,60p' /root/proxy-config.hcl
```

在后台启动 Vault Proxy。

```bash
nohup vault proxy -config=/root/proxy-config.hcl > /tmp/vault-proxy.log 2>&1 &
```

确认进程已启动，并查看日志中 Auto-auth 与 listener 的输出。

```bash
cat /tmp/vault-proxy.pid
ps -fp "$(cat /tmp/vault-proxy.pid)"
tail -30 /tmp/vault-proxy.log
```

现在用一个**没有 token** 的 CLI 通过 Proxy 读取机密。关键是把 `VAULT_ADDR` 指向 Proxy 的 listener、并把 `VAULT_TOKEN` 显式清空。

```bash
VAULT_ADDR=http://127.0.0.1:8100 VAULT_TOKEN= vault kv get secret/seven/app
```

由于 `api_proxy.use_auto_auth_token = "force"`，即便请求没带 token，Proxy 也会用自己的 Auto-auth token 代为转发，因此读取仍然成功。

作为对照，再尝试越权读取一条根本没有授权的路径。Auto-auth token 关联的 policy `seven-app-read` 只允许读 `secret/data/seven/app`，越权请求应被 Vault 拒绝并返回 403。

```bash
VAULT_ADDR=http://127.0.0.1:8100 VAULT_TOKEN= vault kv get secret/foo 2>&1 | tail -5
```

记录下方式三的关键事实：

- **认证主体**：Proxy 通过 AppRole 自动登录得到的 Auto-auth token；应用请求中即使不带 token 也会被强制替换为这枚 token。
- **令牌存放位置**：Proxy 进程内部状态，附带写入 `/root/proxy-token` 的 file sink。
- **机密呈现形式**：HTTP 响应（CLI 把它打印到标准输出），与方式一相同。
- **缓存归属**：Proxy 内部管理由自身新建的 token 与租约；具体缓存边界与清理 API 详见 5.6 节。
