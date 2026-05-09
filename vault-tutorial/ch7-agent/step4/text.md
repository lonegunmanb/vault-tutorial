# 第四步：Process Supervisor 注入环境变量

查看 Process Supervisor Agent 的配置。重点观察 `env_template` 和 `exec`：前者把机密映射成环境变量，后者启动子进程 `/root/supervised-app.sh`。

```bash
sed -n '1,120p' /root/agent-supervisor.hcl
```

启动 Process Supervisor Agent。

```bash
nohup vault agent -config=/root/agent-supervisor.hcl > /tmp/vault-agent-supervisor.log 2>&1 &
```

确认 Agent 与子进程已经启动，并查看子进程记录到 `/tmp/supervised-app.log` 的环境变量值。

```bash
cat /tmp/vault-agent-supervisor.pid
ps -fp "$(cat /tmp/vault-agent-supervisor.pid)"
pgrep -af supervised-app.sh
cat /tmp/supervised-app.log
```

再次更新 KV v2 机密。由于 `restart_on_secret_changes = "always"`，Agent 在检测到静态机密刷新后会停止旧子进程，并用新的环境变量重新启动它。

```bash
vault kv put secret/agent/app \
  username='agent-user' \
  password='supervisor-password' \
  api_key='supervisor-api-key'
```

等待日志中出现新的启动记录。

```bash
for i in $(seq 1 25); do
  if grep -q 'supervisor-password' /tmp/supervised-app.log; then
    echo "supervised child restarted with new environment"
    cat /tmp/supervised-app.log
    break
  fi
  echo "waiting for supervised child restart..."
  sleep 2
done
```

最后查看 Agent 日志，确认它承担的是“渲染环境变量并监督子进程”的职责，而不是让应用直接调用 Vault API。

```bash
tail -80 /tmp/vault-agent-supervisor.log
```

完成本步骤后，你已经体验了 Vault Agent 的两条核心交付路径：文件模板渲染适合读取配置文件的应用，Process Supervisor Mode 适合读取环境变量的子进程。