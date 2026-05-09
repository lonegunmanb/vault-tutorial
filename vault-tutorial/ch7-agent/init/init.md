# 实验说明

本实验将启动一个本地 Vault dev server，并预置一条 KV v2 机密 `secret/agent/app`，以及一个只允许读取该路径的 AppRole `agent-lab`。

你将依次完成两类 Vault Agent 接入方式：

1. 启动一个文件模板 Agent，用 AppRole 自动认证，把 KV 机密渲染到 `/root/agent-demo/app.env`。
2. 更新 KV 机密，观察 `static_secret_render_interval` 到期后文件自动刷新。
3. 启动一个 Process Supervisor Agent，把同一份 KV 机密注入到子进程环境变量中。
4. 再次更新 KV 机密，观察 Agent 重新渲染环境变量并重启子进程。

本实验不使用 Agent 的 API proxy 能力。该能力已被官方标记为 deprecated；如果需要代理 Vault API，请在后续章节使用 Vault Proxy。