# 第三步：Vault Agent Process Supervisor 把同一份凭据注入环境变量

第二条路径：让 **Vault Agent Process Supervisor Mode** 直接 `exec` 启动 `legacy-app`，把动态用户名 / 密码以环境变量 `DB_USER` / `DB_PASSWORD` 注入。租约到 `max_ttl` 之前 Agent 会静默续期（应用完全无感）；一旦 Vault 拒绝再续、Agent 必须重取一份新凭据时，`env_template` 渲染出的值变了，`restart_on_secret_changes = "always"` 才会触发：当前子进程被 `SIGTERM` 掉，再以新环境变量重新拉起——对应用而言相当于一次"无感重启"。

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

预期看到 Agent 完成 AppRole 登录、渲染两个 `env_template`、然后打印类似 `agent.exec.server: [INFO] (child) spawning: /usr/local/bin/legacy-app`。`legacy-app` 自己的 stdout 与 Agent 的日志会混在同一个文件里——这是 Process Supervisor Mode 的设计：子进程的 stdout/stderr 直接继承自 Agent。

如果日志里立刻出现 `[legacy-app] ... OK source=env v-approle-readonly-XXXX @ ...`，说明：

1. Agent 已经从 Vault 拿到了一份新的 readonly 动态凭据（`v-approle-...` 前缀表明这份凭据是 Agent 拿着 AppRole token 取的，不是前面十面 root token 拼出来的 `v-token-...`）；
2. 通过环境变量传给二进制；
3. 二进制走的是“env 分支”而不是“file 分支”。

> 顺手验证一下"环境变量分支"确实在生效——`legacy-app` 自己加打的 `source=env` 标签即是证据。

## 3.3 等 max_ttl 到点，观察 Agent 重启子进程

跟 §2.5 一样，`database/creds/readonly` 的 lease **默认可续期**，Vault Agent 内嵌的渲染器会在 lease 三分之一处静默续期同一份凭据，直到累计存活逼近 `max_ttl = 2m`——这时 Vault 拒绝再续，Agent 重取一份全新凭据（新 username / password），env_template 渲染出不同的值，`restart_on_secret_changes = "always"` 才触发：当前 `legacy-app` 子进程被 SIGTERM 掉，再以新环境变量重新拉起。所以等 30 秒看不到任何动静（你会看到同一个 `v-approle-readonly-XXXX` 用户名一直被复用），必须等到 max_ttl 那一刻。

```bash
sleep 130
echo '--- 130 秒后的 agent.log ---'
tail -n 50 /var/log/legacy-app/agent.log
```{{exec}}

按时间顺序找下面这几条标志（都是 INFO 级别，默认配置就看得到）：

```text
agent: (runner) rendered "(dynamic)" => "DB_USER"
agent: (runner) rendered "(dynamic)" => "DB_PASSWORD"
agent.exec.server: [INFO] (child) spawning: /usr/local/bin/legacy-app
[legacy-app] HH:MM:SS OK    source=env v-approle-readonly-YYYY @ ...
```

前两条说明 Agent 拿到了新凭据、把它重新渲染进 env_template；第三条是 Process Supervisor 看到渲染值变了之后把旧子进程停掉、再 spawn 一个新的；第四条里的 `YYYY` 与启动时的 `XXXX` 不同——同一二进制、不重写任何配置文件、也不用 SIGHUP，应用就吃到了刚生成的凭据。

> 一个细节：lease 在 max_ttl 之前的反复续期，Agent 内嵌的渲染器（跟 §2 里独立 CLI 的 Consul-Template 同源）把它写在 TRACE 级别，默认 INFO 看不到；想看的话给 `vault-agent.hcl` 最外层加 `log_level = "trace"` 后重启。

## 3.4 用 ps 验证父子关系

```bash
ps -ef | grep -E 'vault agent|legacy-app' | grep -v grep
```{{exec}}

会看到一行 `vault agent -config=...`，下面是一行 `legacy-app`，**父进程 PID 就是 Vault Agent**。这就是"Process Supervisor"——子进程的生命周期完全挂在 Agent 身上。
