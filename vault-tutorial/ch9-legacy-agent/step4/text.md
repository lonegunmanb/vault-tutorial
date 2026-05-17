# 第四步：对比两条路径并观察 lease 在 Postgres 端的真实生命周期

## 4.1 用 Postgres 端的视角看租约在滚动

在 Agent 还跑着的同时，连续两次 dump `pg_user`，两个时间点之间的差异就是 Vault 帮你做的事：

```bash
echo '--- T0 ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token-readonly%' ORDER BY usename;"
sleep 25
echo '--- T0 + 25s ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token-readonly%' ORDER BY usename;"
```{{exec}}

预期：T0 时刻通常只有 1 个（当前 Agent 用的那个）`v-token-readonly-` 用户；25 秒后可能短暂出现 2 个（新旧用户重叠）或者旧用户已经被 `DROP ROLE` 掉、只剩新用户。这与 9.8 节里讲到的 lease 续期 / 滚动机制对得上。

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
tail -n 25 /var/log/legacy-app/agent.log
```{{exec}}

如果撤的是当前 Agent 正在用的那条，预期会看到 Agent 重新渲染 `env_template`、`restart child process`、新一条 `[legacy-app] ... OK source=env v-token-readonly-ZZZZ ...` 出现。

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
