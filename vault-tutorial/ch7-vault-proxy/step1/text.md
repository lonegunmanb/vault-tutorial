# 第一步：启动 `use_auto_auth_token = true` 的 Proxy

先确认 Vault dev server 已经可用，并查看本实验预置的目标机密。

```bash
vault status
vault kv get secret/proxy73/app
```

查看 Proxy 将使用的 AppRole 与 policy。`proxy73-app-read` 只允许读取 `secret/data/proxy73/app`，这就是 Proxy Auto-auth token 的权限边界。

```bash
vault read auth/approle/role/proxy73-app
vault policy read proxy73-app-read
```

再查看用于对照的低权限 token。它只带有 `proxy73-no-read` policy，不能读取目标机密。

```bash
vault policy read proxy73-no-read
VAULT_TOKEN="$(cat /root/no-read-token)" vault token lookup | grep -E 'display_name|policies|ttl'
```

阅读第一个 Proxy 配置文件。重点观察 `api_proxy`：这里设置的是 `use_auto_auth_token = true`，表示请求没有 token 时，Proxy 会使用自己的 Auto-auth token；如果请求已经带 token，则请求自带 token 会优先生效。

```bash
sed -n '1,120p' /root/proxy-config-true.hcl
```

启动第一个 Proxy，它会监听 `127.0.0.1:8100`。

```bash
nohup vault proxy -config=/root/proxy-config-true.hcl > /tmp/proxy-true.log 2>&1 &
```

确认进程已经启动，并观察 Auto-auth 是否成功。

```bash
cat /tmp/proxy-true.pid
ps -fp "$(cat /tmp/proxy-true.pid)"
tail -40 /tmp/proxy-true.log
test -s /root/proxy73-true-token && echo "true-mode sink token is ready"
```

这一阶段的关键点是：Proxy 已经拥有一枚通过 AppRole 自动取得的 Vault token，但 `use_auto_auth_token = true` 并不意味着它会覆盖每一个请求自带的 token。