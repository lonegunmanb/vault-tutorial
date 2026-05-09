# 实验完成

你已经完成本节 Vault Agent 实验，并验证了以下事实：

- Agent 可以通过 Auto-auth 代表应用取得最小权限 token。
- 文件型 `template` 可以把 KV v2 机密渲染成本地配置文件。
- 对 KV v2 这类没有 lease 的静态机密，`static_secret_render_interval` 决定 Agent 重新渲染的周期。
- Process Supervisor Mode 可以通过 `env_template` 把机密注入子进程环境变量。
- 当 `restart_on_secret_changes = "always"` 时，机密变化会触发子进程重启，使新环境变量生效。

请保留“Agent 供给文件或环境变量，Proxy 代理 Vault API”这一边界。下一节会继续进入 Vault Proxy 的代理拓扑与缓存边界。