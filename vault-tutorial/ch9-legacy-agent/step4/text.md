# 第四步：对比两条路径并观察 lease 在 Postgres 端的真实生命周期

## 4.1 用 Postgres 端的视角看租约在滚动

在 Agent 还跑着的同时，连续两次 dump `pg_user`，两个时间点之间的差异就是 Vault 帮你做的事：

先打一次 T0 快照：

```bash
echo '--- T0 ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%readonly%' ORDER BY usename;"
```{{exec}}

等大约 35 秒（略大于 `default_ttl=30s`，确保跨过一次 lease 滚动），再打一次 T1 快照：

```bash
sleep 35
echo '--- T0 + 35s ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-%readonly%' ORDER BY usename;"
```{{exec}}

预期：T0 时刻通常只有 1 个（当前 Agent 用的那个）`v-approle-readonly-` 用户（如果是从 §2 残留下来的环境，前缀可能是 `v-token-readonly-`）；T1 时可能短暂出现 2 个（新旧用户重叠）或者旧用户已经被 `DROP ROLE` 掉、只剩新用户——`usename` 后缀或 `valuntil` 与 T0 不同就说明滚过了。这与 9.8 节里讲到的 lease 续期 / 滚动机制对得上。

## 4.2 从 Vault 角度看 lease

```bash
vault list sys/leases/lookup/database/creds/readonly
```{{exec}}

会列出当前还活着的 lease。每条对应 Postgres 端的一个动态用户。

## 4.3 主动撤一条 lease，看 Agent 反应

随便挑一条 lease 看一下：

```bash
LEASE_ID=$(vault list -format=json sys/leases/lookup/database/creds/readonly | jq -r '.[0]')
FULL_LEASE="database/creds/readonly/$LEASE_ID"
echo "Going to revoke: $FULL_LEASE"
vault lease revoke "$FULL_LEASE"
sleep 5
echo '--- agent.log: rotation evidence ---'
grep -E 'renewer done|rendered .* DB_(USER|PASSWORD)|stopping process|spawning:|source=env' /var/log/legacy-app/agent.log | tail -n 15
```{{exec}}

上面那条 `grep` 把日志压缩成 5 类关键证据行，按时间顺序读下来就是 Agent 的完整反应链路：

1. `renewer done (maybe the lease expired)` —— Vault Agent 发现旧 lease 没了（因为你刚撤的就是它）；
2. `rendered "(dynamic)" => "DB_USER"` / `"DB_PASSWORD"` —— Agent 重新执行 env_template，拿到一对全新的用户名 / 密码；
3. `stopping process` —— `restart_on_secret_changes = "always"` 触发，旧 `legacy-app` 子进程被 SIGTERM；
4. `spawning: /usr/local/bin/legacy-app` —— Agent 用新环境变量重新拉起子进程；
5. `[legacy-app] ... OK source=env v-approle-readonly-ZZZZ ...` —— 新进程用新凭据连 Postgres 成功，且 `ZZZZ` 后缀和撤销前那条不一样。

如果撤的恰好不是当前 Agent 在用的那条 lease，就只会看到 `source=env` 一类的行而没有 stopping/spawning——这时再跑一次 4.3 即可（lease 列表里第一条不一定就是 Agent 自己那条）。

> 这一步把"被动到期"换成了"主动撤销"，更直观地说明 Agent 是按 secret 变化而不是按计时器在驱动重启。

## 4.4 收尾：两条路径互斥，不能同时跑

为下一位学员留一个干净环境，把 Agent 和（如果还在跑的）残留 `legacy-app` 都停掉：

```bash
kill "$(cat /var/run/vault-agent.pid)" 2>/dev/null || true
pkill -f /usr/local/bin/legacy-app 2>/dev/null || true
sleep 2
pgrep -af 'vault agent' || echo 'vault agent stopped'
pgrep -af legacy-app || echo 'legacy-app stopped'
```{{exec}}

到这里，9.8 节描述的两条接入路径都在同一台主机上跑通了：

1. **Consul-Template + 配置文件**：渲染—写盘—等应用自己重读，适合本来就有重新加载机制的旧服务；
2. **Vault Agent Process Supervisor + 环境变量**：Agent 当 init 用，子进程在 lease 滚动时被透明重启，适合那种"启动一次就再也不重读配置"的二进制——也就是本实验里这个故意写死的 `legacy-app`。
