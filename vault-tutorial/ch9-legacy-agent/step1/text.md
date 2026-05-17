# 第一步：检查遗留应用与 Vault PostgreSQL 动态机密引擎

打开右侧终端，确认基础组件都已就位。

## 1.1 确认 Vault、PostgreSQL、AppRole 都已就绪

```bash
vault status | head -6
docker ps --filter name=learn-postgres --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
vault read auth/approle/role/legacy-agent
ls -l /root/agent-role-id /root/agent-secret-id
```{{exec}}

Vault 应处于 `Initialized=true, Sealed=false`，Postgres 容器在跑，AppRole `legacy-agent` 已存在，两个文件各 600 权限。

## 1.2 查看 readonly role 配置

```bash
vault read database/roles/readonly
```{{exec}}

重点确认 `default_ttl = 30s`、`max_ttl = 10m`、`creation_statements` 里包含 `GRANT ro TO "{{name}}"`。30 秒 TTL 是为了让你直观看到租约滚动，不是生产推荐值。

## 1.3 手动签发一份动态凭据

```bash
vault read -format=json database/creds/readonly | tee /tmp/cred1.json | jq '{lease_id, lease_duration, username: .data.username}'
```{{exec}}

留意三件事：

- `username` 形如 `v-token-readonly-XXXXXX`，是 Vault 刚在 Postgres 端 `CREATE ROLE` 出来的真实用户；
- `lease_duration` = 30；
- 同时去 Postgres 一侧验证：

```bash
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename FROM pg_user WHERE usename LIKE 'v-token-readonly%';"
```{{exec}}

应能看到刚刚那个用户名。30 秒后再执行一次，会发现这一行消失——Vault 把租约到期的用户 `DROP ROLE` 掉了。

## 1.4 用刚才那条凭据手动驱动一次 `legacy-app`

把它写进 `/etc/legacy-app/config.toml`，然后直接运行二进制：

```bash
DB_USER=$(jq -r '.data.username' /tmp/cred1.json)
DB_PASS=$(jq -r '.data.password' /tmp/cred1.json)
cat > /etc/legacy-app/config.toml <<EOF
[database]
host = "localhost"
port = 5432
username = "$DB_USER"
password = "$DB_PASS"
EOF
timeout 8 /usr/local/bin/legacy-app
```{{exec}}

预期输出大致是：

```
[legacy-app] starting
[legacy-app] 12:34:56 OK    source=file v-token-readonly-XXXX @ 2025-...
```

`source=file` 说明二进制刚才是从配置文件读到了凭据。

也可以试一下环境变量分支：

```bash
DB_USER=$DB_USER DB_PASSWORD=$DB_PASS timeout 5 /usr/local/bin/legacy-app
```{{exec}}

这次 `source=env`。两条读取路径都验证 OK，意味着接下来无论是 Consul-Template（更新文件）还是 Vault Agent Process Supervisor（注入环境变量），都能把这个"无法改造"的二进制喂饱。

> 30 秒后那个 `v-token-readonly-XXXX` 用户会被 Vault 自动 revoke，再用旧凭据连 Postgres 会失败——这正是 9.8 节里强调的"不接入自动化就只能眼看着应用挂掉"的现象。下一步开始把这件事自动化。
