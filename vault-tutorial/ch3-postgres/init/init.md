# 实验：PostgreSQL 数据库机密引擎

[3.14 PostgreSQL 数据库机密引擎](/ch3-postgres) 讲清楚了 `postgresql-database-plugin`
在 Vault Database 引擎下的形状（连接配置 / Dynamic Role / Static Role）以及与企业版功能
（Rootless、IAM）的边界。本实验在一个真实的 PostgreSQL 16 容器上把开源版能跑的全部模式
跑一遍，并用 `psql` 从 PG 端反向验证 Vault 的所有写操作确实落到了数据库里。

---

## 实验环境

后台脚本会自动准备好：

- **PostgreSQL 16** 容器（`postgres:16`），监听 `127.0.0.1:5432`，默认 db `postgres`
  - 超级用户 `root` / `rootpassword`（仅供你调试 / 旁路验证用）
  - **Vault root** 账号 `vaultadmin` / `vaultadmin`（拥有 `CREATEROLE`，由 step1 写入 `database/config/postgres-main`）
  - 既有应用账号 `legacy_app` / `legacy-pass`（step3 演示 Static Role 平滑接管）
  - 演示表 `demo.kv (k,v)` 预置两行
- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- 工具：`psql`、`jq`、`docker`

---

## 你将亲手验证的事实

1. `vault write database/config/postgres-main ...` 之后 `vault write -force database/rotate-root/postgres-main`
   立刻让 `vaultadmin` 在 PG 端的密码变成"只有 Vault 才知道"的随机串
2. `vault read database/creds/<role>` 每次读都在 PG 里**新建一个临时 ROLE**，临时账号能用
   返回的密码登 PG 并 SELECT 演示表
3. `vault lease revoke <id>` 立刻让该临时账号从 `pg_roles` 消失；不主动 revoke 时 Lease TTL 到也会清理
4. Static Role 在 onboarding `legacy_app` 时，**默认**会立刻覆盖 `legacy-pass`；用 `skip_import_rotation=true`
   可保留原密码以平滑切换；手动 `vault write -f database/rotate-role/<name>` 触发轮转
5. `password_authentication="scram-sha-256"` 让 PG 内 `pg_authid.rolpassword` 以 `SCRAM-SHA-256$...` 形式存储
6. `allowed_roles` 可用通配符限制哪些 role 名可以挂在某条连接下

预期耗时：20 ~ 30 分钟（含 PostgreSQL 镜像拉取约 30 秒）。
