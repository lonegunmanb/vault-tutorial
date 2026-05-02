# 实验：MySQL/MariaDB 数据库机密引擎

[3.15 MySQL/MariaDB 数据库机密引擎](/ch3-mysql) 严格按官方 MySQL/MariaDB 引擎文档和插件 API 页梳理了 `mysql-database-plugin` 的核心路径：`database/config/<name>` 写连接，`database/roles/<name>` 写 Dynamic Role，`database/creds/<role>` 申领短寿命凭据。

本实验在一个真实 MySQL 8 容器里跑通可本地验证的部分：root credential rotation、Dynamic Role、Lease revoke、wildcard grant 与 base64 creation statement。x509 与 GCP CloudSQL IAM 需要证书或云资源，本实验会在最后一步给出命令形状和参数核对，不强行伪造云环境。

---

## 实验环境

后台脚本会自动准备好：

- **MySQL 8** 容器，监听 `127.0.0.1:3306`
  - 超级用户 `root` / `rootpassword`（只用于旁路验证）
  - Vault root 账号 `vaultadmin` / `vaultadmin`（写入 `database/config/mysql-main` 后由 Vault 接管）
  - 演示库 `appdb.kv`，预置 `hello/world` 与 `vault/rocks`
  - wildcard 演示库 `fooapp_alpha.audit`
- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- 工具：`vault`、`mysql`、`jq`、`docker`

---

## 你将亲手验证的事实

1. `database/config/mysql-main` 里使用 `plugin_name=mysql-database-plugin` 与模板化 `connection_url`。
2. `vault write -force database/rotate-root/mysql-main` 后，`vaultadmin` 的旧密码立即失效。
3. `vault read database/creds/readonly` 每次都会在 MySQL 里创建一个临时用户，并返回 `username` / `password` / `lease_id`。
4. `vault lease revoke <lease_id>` 后，临时用户会被 `DROP USER` 清掉。
5. 带反引号的 wildcard grant 需要 base64 后再传给 Vault，避免 shell 把反引号当命令执行。
6. x509 与 GCP IAM 的参数形状来自官方 API 页和引擎页，但需要外部证书或 CloudSQL 环境才能真正连通。

预期耗时：20 分钟左右，首次拉取 MySQL 镜像可能稍慢。
