# 第 1 步：启用 database/、配置 MySQL 连接、rotate-root

官方 MySQL/MariaDB 文档的前三步是：启用 `database/`，写入 `database/config/<name>`，再创建 `database/roles/<role>`。本步先完成前两件事，并顺手验证 root credential rotation。

---

## 1.1 启用 database/ 引擎

```bash
vault secrets enable database
vault secrets list | grep -E "Path|database"
```

应看到 `database/    database    ...`。

## 1.2 确认 `vaultadmin` 初始密码可用

后台已经在 MySQL 里预置了 `vaultadmin` / `vaultadmin`。先确认它能登录，后面 rotate-root 后再对比。

```bash
mysql -h 127.0.0.1 -uvaultadmin -pvaultadmin -Nse "SELECT CURRENT_USER();"
# 应看到类似: vaultadmin@%
```

## 1.3 写入连接配置

官方示例使用 `mysql-database-plugin` 和模板化 `connection_url`。这里我们把连接名叫 `mysql-main`。

```bash
vault write database/config/mysql-main \
  plugin_name="mysql-database-plugin" \
  connection_url="{{username}}:{{password}}@tcp(127.0.0.1:3306)/" \
  allowed_roles="my-role,readonly,wildcard-role" \
  username="vaultadmin" \
  password="vaultadmin" \
  max_open_connections=5 \
  max_connection_lifetime="5s"
```

读回来确认：

```bash
vault read database/config/mysql-main
```

你应该能看到顶层的 `plugin_name`、`allowed_roles`，以及 `connection_details` 里的
`connection_url`、`max_open_connections`、`max_connection_lifetime`、`username` 等连接细节；
密码不会明文回显。

## 1.4 轮转 root credential

```bash
vault write -force database/rotate-root/mysql-main
```

这一步会让 Vault 用当前的 `vaultadmin` 凭据连上 MySQL，然后把 `vaultadmin` 的密码改成 Vault 内部保存的新随机密码。

## 1.5 旁路验证旧密码已失效

```bash
mysql -h 127.0.0.1 -uvaultadmin -pvaultadmin -Nse "SELECT 1;" 2>&1 | head -3
```

应看到 `Access denied`。这说明旧密码 `vaultadmin` 已经不能用了。

root 超级用户仍能旁路查看账号存在：

```bash
mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT user, host FROM mysql.user WHERE user IN ('vaultadmin','legacy_app') ORDER BY user;"
```

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `database/`
- [ ] `vault read database/config/mysql-main` 能读到连接配置
- [ ] `rotate-root` 后，`vaultadmin` 的旧密码登录失败
- [ ] root 旁路查询仍能看到 `vaultadmin` 账号存在
