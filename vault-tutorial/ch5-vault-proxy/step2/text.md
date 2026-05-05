# 第二步：启动 `vault proxy` 并观察 Auto-auth

在后台启动 Proxy。

```bash
nohup vault proxy -config=/root/proxy-config.hcl > /tmp/vault-proxy.log 2>&1 &
```

确认进程和 pid 文件已经出现。

```bash
cat /tmp/vault-proxy.pid
ps -fp "$(cat /tmp/vault-proxy.pid)"
```

查看日志中与 Auto-auth 有关的信息。

```bash
tail -40 /tmp/vault-proxy.log
```

确认 file sink 已写入 token。不要把真实生产 token 打印到终端；本实验是临时 dev server，因此只显示前几个字符和 token 查询结果。

```bash
test -s /root/proxy-token && echo "proxy token sink is ready"
cut -c 1-12 /root/proxy-token && echo "..."
VAULT_TOKEN=$(cat /root/proxy-token) vault token lookup | grep -E 'display_name|policies|ttl'
```

现在用 Proxy token 直接验证它确实只能读取实验机密。

```bash
VAULT_TOKEN=$(cat /root/proxy-token) vault kv get secret/proxy/app
VAULT_TOKEN=$(cat /root/proxy-token) vault secrets list 2>&1 | tail -4
```

第二条命令应失败，因为 `proxy-app-read` policy 没有系统管理权限。这个失败非常重要：稍后通过 Proxy 转发的请求也只会拥有同样的最小权限。
