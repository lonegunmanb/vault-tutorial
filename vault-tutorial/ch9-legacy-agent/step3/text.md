# 第三步：Vault Agent Process Supervisor 把同一份凭据注入环境变量

第二条路径：让 **Vault Agent Process Supervisor Mode** 直接 `exec` 启动 `legacy-app`，把动态用户名 / 密码以环境变量 `DB_USER` / `DB_PASSWORD` 注入。租约接近过期时，Agent 根据 `restart_on_secret_changes = "always"` 给子进程发 `SIGTERM`，再以新凭据重新拉起——对应用而言相当于一次"无感重启"。

## 3.1 看一眼 Agent 配置

```bash
cat /root/legacy-lab/vault-agent.hcl
```{{exec}}

关注三件事：

- `auto_auth` 用 AppRole 拿 token（不用借 root 给 Agent）；
- 两个 `env_template`，模板里都用 `{{ with secret "database/creds/readonly" }}`——意味着 Agent 会把 `DB_USER` / `DB_PASSWORD` 绑定到同一份动态机密的两个字段；
- 必须有恰好一个 `exec` 块，命令就是我们那个无法改造的二进制；`restart_on_secret_changes = "always"` 是触发重启的开关。

> 提示：Process Supervisor Mode 与"把渲染结果写文件"的 `template` 块互斥——同一份 Agent 配置里不能同时出现普通的 `template { destination = ... }` 与 `env_template`。

## 3.2 启动 Vault Agent，让它接管 `legacy-app`

```bash
nohup vault agent -config=/root/legacy-lab/vault-agent.hcl \
  > /var/log/legacy-app/agent.log 2>&1 &
echo $! > /var/run/vault-agent.pid
sleep 4
tail -n 30 /var/log/legacy-app/agent.log
```{{exec}}

预期看到 Agent 完成 AppRole 登录、渲染两个 `env_template`、然后打印类似 `executing command "/usr/local/bin/legacy-app"`。`legacy-app` 自己的 stdout 与 Agent 的日志会混在同一个文件里——这是 Process Supervisor Mode 的设计：子进程的 stdout/stderr 直接继承自 Agent。

如果日志里立刻出现 `[legacy-app] ... OK source=env v-token-readonly-XXXX @ ...`，说明：

1. Agent 已经从 Vault 拿到了一份新的 readonly 动态凭据；
2. 通过环境变量传给了二进制；
3. 二进制走的是"env 分支"而不是"file 分支"。

> 顺手验证一下"环境变量分支"确实在生效——`legacy-app` 自己加打的 `source=env` 标签即是证据。

## 3.3 等 lease 临近过期，观察 Agent 重启子进程

```bash
sleep 35
echo '--- 35 秒后的 agent.log ---'
tail -n 40 /var/log/legacy-app/agent.log
```{{exec}}

预期会出现两类关键行：

- `[INFO] (runner) rendered ...` 或 `secret ... renewed`：Agent 检测到 lease 接近 default_ttl 时尝试续期，对 `database/creds` 这类**不可续期**的动态机密会失败，转而申请一份新凭据；
- `restarting child process` / `child process started`：Agent 给当前 `legacy-app` 进程发 SIGTERM，再用新环境变量重新拉起。

紧随其后的 `[legacy-app] ... OK source=env v-token-readonly-YYYY @ ...` 里，`YYYY` 已经是新用户名——同一二进制、不重写任何配置文件，也不用 SIGHUP，应用就吃到了刚生成的凭据。

## 3.4 用 ps 验证父子关系

```bash
ps -ef | grep -E 'vault agent|legacy-app' | grep -v grep
```{{exec}}

会看到一行 `vault agent -config=...`，下面是一行 `legacy-app`，**父进程 PID 就是 Vault Agent**。这就是"Process Supervisor"——子进程的生命周期完全挂在 Agent 身上。
