# 恭喜完成 PostgreSQL 数据库机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| **Step 1** | `vault write database/config/postgres-main` 接管 `vaultadmin`；`-force database/rotate-root/<name>` 之后旧密码立即作废 |
| **Step 2 Dynamic** | 每次 `vault read database/creds/<role>` 都在 `pg_roles` 中现场创建一条临时 ROLE；revoke 或 TTL 过期时按 `revocation_statements` 自动 `DROP ROLE` |
| **Step 3 Static** | `skip_import_rotation=true` 让 onboarding 不打断现有应用；`rotate-role` 与 `rotation_period` 都能让旧密码瞬间失效、新密码生效 |
| **Step 4 进阶** | `password_authentication="scram-sha-256"` 让密码在 PG 端以 `SCRAM-SHA-256$...` 哈希存储；`allowed_roles` 含通配符的安全围栏在凭据申领时点强制生效 |

## Dynamic vs Static 同图速记

```
                 PostgreSQL Database 引擎的两种使用模式
        ┌──────────────────┬───────────────────────────────┐
        │     Dynamic      │            Static             │
        ├──────────────────┼───────────────────────────────┤
账号    │ 短寿命，每次新建 │ 长寿命，PG 里已存在的 1:1 映射│
密码    │ 创建时一次       │ 周期 / cron 自动轮转          │
谁建账号│ Vault            │ DBA 在 PG 端预先创建          │
谁删账号│ Vault (Lease)    │ 不删                          │
有 Lease│ 是               │ 否                            │
适合    │ 一次性消费、审计 │ 老旧应用、固定连接配置        │
路径    │ database/roles/  │ database/static-roles/        │
                            │ database/static-creds/        │
        └──────────────────┴───────────────────────────────┘
```

## 三个最容易踩的坑（与 [3.14 §9](/ch3-postgres) 互参）

1. **不要把 root 用户挂成 Static Role**——Vault 不区分 root 与普通账号，一旦轮转 root，
   `database/config/<name>` 立即失效，后续所有 dynamic / static 都用不了。要轮 root 永远走 `database/rotate-root/<name>`。

2. **`skip_import_rotation` 要在 onboarding 那一刻就给**——一旦默认行为执行了第一次轮转，
   旧密码就回不去了；存量接管务必同时用 `skip_import_rotation=true` 与（可选）`password=<现有密码>`。

3. **`rotation_period` 与 `rotation_schedule` 互斥**——两者只能选一个。要 cron 表达式调度就用后者，
   要简单的"N 秒一轮"就用前者。

## 与下一节的衔接

- 本节是 Database 引擎下的 **PostgreSQL** 插件；MySQL / MSSQL / Oracle 等其它数据库走完全相同的 `database/` 路径模型，
  差异只在 plugin_name 与 SQL 模板。
- 想反过来 **让 PG 用户用 PG 账号登录 Vault**？那是未来 7.X 章节会讲的"用户型认证方法"（与本节正交）。

**返回文档**：[3.14 PostgreSQL 数据库机密引擎](/ch3-postgres)
