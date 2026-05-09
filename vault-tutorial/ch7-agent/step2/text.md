# 第二步：模板渲染为本地文件

在后台启动文件模板 Agent。

```bash
nohup vault agent -config=/root/agent-file.hcl > /tmp/vault-agent-file.log 2>&1 &
```

确认 Agent 进程已经启动，并查看最近的日志。

```bash
cat /tmp/vault-agent-file.pid
ps -fp "$(cat /tmp/vault-agent-file.pid)"
tail -40 /tmp/vault-agent-file.log
```

确认 file sink 已经写出 token，并确认模板文件已经渲染完成。

```bash
test -s /root/agent-demo/file-agent-token && echo "file sink token is ready"
ls -l /root/agent-demo/app.env
cat /root/agent-demo/app.env
```

此时应用可以把 `/root/agent-demo/app.env` 当成普通配置文件读取。请注意：应用看到的是渲染后的文件，不需要知道 AppRole、Auto-auth 或 Vault API 的细节。

作为权限边界检查，用 Agent sink token 读取授权路径应成功，读取未授权路径应失败。

```bash
AGENT_TOKEN="$(cat /root/agent-demo/file-agent-token)"
VAULT_TOKEN="$AGENT_TOKEN" vault kv get secret/agent/app
VAULT_TOKEN="$AGENT_TOKEN" vault kv get secret/other 2>&1 | tail -5
```

第二条命令预期返回 permission denied。这个结果说明 Agent 拿到的是最小权限 token，而不是 dev server 的 root token。