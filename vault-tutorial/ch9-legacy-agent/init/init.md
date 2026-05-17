# 实验说明

本实验复现 9.8 节正文里"无法改造的遗留 Go 应用 + PostgreSQL 动态机密引擎"这一公共背景，让你在同一台主机上、用同一份 Vault 配置与同一个二进制，分别跑通两条接入路径：**Consul-Template 把动态凭据渲染成 TOML 配置文件**、**Vault Agent Process Supervisor 把同一份凭据注入环境变量**。

环境会预先准备好：

- dev 模式 Vault：`VAULT_ADDR=http://127.0.0.1:8200`，root token 为 `root`；
- PostgreSQL 容器：`localhost:5432`，superuser `root` / `rootpassword`，预创建一个 `ro` 只读角色；
- Vault `database` 机密引擎已配置好 PostgreSQL 连接，并启用一个 `default_ttl = 30s` 的 role `readonly`（动态用户从 `ro` 继承读权限）；
- 一个故意写成"无法改造"的 Go 二进制 `/usr/local/bin/legacy-app`：
  - 优先从环境变量 `DB_USER` / `DB_PASSWORD` 读取凭据；
  - 没有环境变量时回退去读 `/etc/legacy-app/config.toml`；
  - 每 10 秒用 `psql` 连一次 Postgres，打印 `current_user` 与 `now()`；
- AppRole `legacy-agent`，role-id / secret-id 已写入 `/root/agent-role-id` / `/root/agent-secret-id`，绑定一条只允许读 `database/creds/readonly` 的策略；
- 现成的配置文件骨架：
  - `/root/legacy-lab/config.toml.tplt` 与 `/root/legacy-lab/ct_config.hcl`（Consul-Template）；
  - `/root/legacy-lab/vault-agent.hcl`（Vault Agent Process Supervisor）；
- `psql` 与 `jq` 已安装，便于在终端直接查询 Postgres 与解析 Vault 响应。

你将依次完成四步：

1. 跑一次 `legacy-app` 验证它的两种读取路径都工作；
2. 启动 **Consul-Template**，让它把 30 秒 TTL 的 PostgreSQL 动态用户名 / 密码渲染进 `/etc/legacy-app/config.toml`，配合后台运行的 `legacy-app` 观察文件刷新与连接切换；
3. 关掉 Consul-Template，改用 **Vault Agent Process Supervisor Mode** 启动 `legacy-app`，让 Agent 在动态机密接近到期时按 `restart_on_secret_changes = "always"` 重启子进程；
4. 在 Postgres 一侧用 `pg_user` 与 `vault list sys/leases/...` 对比两条路径下租约的真实生命周期。

> 本实验不依赖任何外部云资源，所有服务都跑在本机；可放心反复执行。
