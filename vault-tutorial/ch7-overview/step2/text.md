# 第二步：方式二 —— Vault Agent 模板渲染到文件

查看预置的 Agent 配置文件。重点观察三块：`auto_auth` 描述如何用 AppRole 文件登录、`sink` 描述把取得的 token 写到哪里、`template` 描述要把哪一条机密以什么样的文本格式渲染到本地文件。

```bash
sed -n '1,60p' /root/agent-config.hcl
```

在后台启动 Vault Agent。

```bash
nohup vault agent -config=/root/agent-config.hcl > /tmp/vault-agent.log 2>&1 &
```

确认进程已启动，并查看与 Auto-auth 和 template 渲染有关的日志。

```bash
cat /tmp/vault-agent.pid
ps -fp "$(cat /tmp/vault-agent.pid)"
tail -30 /tmp/vault-agent.log
```

确认 sink token 已经被写入，并确认目标文件已经按照模板渲染完成。

```bash
test -s /root/agent-token && echo "agent token sink is ready"
ls -l /root/agent-secret.txt
cat /root/agent-secret.txt
```

文件内容应为 `username=...` 与 `password=...` 两行，对应模板中引用的 `secret/data/seven/app`。

记录下方式二的关键事实：

- **认证主体**：Agent 通过 AppRole 自动登录得到的 Vault token（写入 `/root/agent-token`）；应用本身不需要持有 token。
- **令牌存放位置**：file sink，本实验在 `/root/agent-token`。
- **机密呈现形式**：本地文件 `/root/agent-secret.txt`，由应用直接读取文件即可。
- **缓存归属**：Agent 在内部维护 token 与租约状态，但应用本身只看到落盘的渲染结果。
