# 第 1 步：启用 database/ 引擎、配置 PostgreSQL 连接、rotate-root

[3.14 §3](/ch3-postgres) 讲过：所有事都从挂载 `database/` 引擎、`vault write database/config/<name>`
告诉 Vault 怎么连 PG、再立刻 `rotate-root` 切断"原 root 密码"开始。本步：

1. `vault secrets enable database`
2. 用 `vaultadmin` / `vaultadmin` 写入 `database/config/postgres-main`
3. `vault write -force database/rotate-root/postgres-main` —— 之后 `vaultadmin` 的旧密码立即作废
4. 旁路用 `psql` 验证旧密码已不可登

---

## 1.1 启用 database/ 引擎

```bash
vault secrets enable database
vault secrets list | grep -E "Path|database"
```

应看到 `database/    database    ...    n/a    n/a    ...`。

## 1.2 写入连接配置（先确认 vaultadmin 旧密码可用）

为了让后续 1.4 的对比更直观，先确认 `vaultadmin` 现在还是初始密码 `vaultadmin`：

```bash
PGPASSWORD=vaultadmin psql -h 127.0.0.1 -U vaultadmin -d postgres \
  -tAc "SELECT current_user;"
# 应输出: vaultadmin
```

写入 Vault 连接配置：

```bash
vault write database/config/postgres-main \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="my-role,readonly,legacy-app,svc-*" \
  connection_url="postgresql://{{username}}:{{password}}@127.0.0.1:5432/postgres?sslmode=disable" \
  username="vaultadmin" \
  password="vaultadmin" \
  password_authentication="scram-sha-256"
```

字段含义见 [3.14 §3.1](/ch3-postgres)。注意：

- `connection_url` 里的 `{{username}}` / `{{password}}` 是 **Vault** 的占位符——不是 PG 的；Vault 在每次连接前注入
- `allowed_roles` 同时约束 Dynamic Role 与 Static Role：`readonly` 给 step2，`legacy-app` 给 step3，`svc-*` 在 step4 演示通配符
- `password_authentication="scram-sha-256"` 强制让 Vault 在 ALTER USER 时把 PG 密码以 SCRAM 形式存
  （PG 16 默认即此，但显式声明便于审计）

读回来确认：

```bash
vault read database/config/postgres-main
```

`password` 字段不会回显（密码不会以明文回读，正常）。

## 1.3 立刻轮转 root —— 切断原密码

```bash
vault write -force database/rotate-root/postgres-main
```

> `-force` 表示这是一个无入参的写操作。轮转后，**新密码只存在于 Vault 内部**，任何 API 都拿不出来。

## 1.4 旁路验证：原 `vaultadmin` 密码已不可用

```bash
PGPASSWORD=vaultadmin psql -h 127.0.0.1 -U vaultadmin -d postgres \
  -tAc "SELECT current_user;" 2>&1 | head -2
# 应输出: psql: error: connection to server at "127.0.0.1" ...
#         FATAL:  password authentication failed for user "vaultadmin"
```

而 `root` 超级用户仍可登（用它在后续 step 做旁路检查）：

```bash
PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname IN ('vaultadmin','legacy_app') ORDER BY 1;"
# 应输出:
# legacy_app
# vaultadmin
```

> 这两个账号都还在；只是 `vaultadmin` 的密码已经被 Vault 替换。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `database/`
- [ ] `vault read database/config/postgres-main` 返回了 `connection_url` / `allowed_roles` / `plugin_name`
- [ ] `rotate-root` 后用旧密码 `vaultadmin` 登 PG 失败（`password authentication failed`）
- [ ] `vaultadmin` 的账号仍存在（只是密码换了）

> **生产警示**：如 [3.14 §3.2](/ch3-postgres) 引官方原文所说，
> **不要把 root 用户挂成 Static Role**。轮 root 永远走 `database/rotate-root/<name>`。
