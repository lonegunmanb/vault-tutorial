# 第 2 步：Dynamic Role —— 现场建 MySQL 用户、实连验证、Lease 回收

官方 MySQL/MariaDB 文档的核心用法是：写 `database/roles/<role>`，然后读 `database/creds/<role>` 生成凭据。本步让 Vault 在 MySQL 里真的 `CREATE USER`，再用返回的用户名密码实连 MySQL。

---

## 2.1 创建 Dynamic Role

```bash
vault write database/roles/readonly \
  db_name="mysql-main" \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON appdb.* TO '{{name}}'@'%';" \
  revocation_statements="DROP USER '{{name}}'@'%';" \
  default_ttl="2m" \
  max_ttl="10m"

vault read database/roles/readonly
```

这里的 `{{name}}` 和 `{{password}}` 是 Vault 占位符。每次申领凭据时，Vault 会把它们替换成随机用户名和随机密码。

## 2.2 申领一份动态凭据

```bash
CRED=$(vault read -format=json database/creds/readonly)
echo "$CRED" | jq

USER=$(echo "$CRED" | jq -r .data.username)
PASS=$(echo "$CRED" | jq -r .data.password)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "临时账号: $USER"
echo "Lease ID: $LEASE"
echo "用户名长度: ${#USER}"
```

`mysql-database-plugin` 的默认用户名模板会把用户名截到 32 个字符以内；你可以直接看 `${#USER}` 验证。

## 2.3 旁路确认 MySQL 用户已创建

```bash
mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT user, host FROM mysql.user WHERE user='$USER';"
```

应看到刚才的临时用户名。

## 2.4 用临时账号实连 MySQL

```bash
mysql -h 127.0.0.1 -u"$USER" -p"$PASS" -Nse "SELECT * FROM appdb.kv;"
```

应看到两行数据：`hello world` 和 `vault rocks`。

## 2.5 Revoke Lease，验证账号被清理

```bash
vault lease revoke "$LEASE"
sleep 1

mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT COUNT(*) FROM mysql.user WHERE user='$USER';"
# 应输出 0

mysql -h 127.0.0.1 -u"$USER" -p"$PASS" -Nse "SELECT 1;" 2>&1 | head -3
# 应看到 Access denied 或用户不存在相关错误
```

## 2.6 再申领一份，让它自然到期

```bash
CRED2=$(vault read -format=json database/creds/readonly)
USER2=$(echo "$CRED2" | jq -r .data.username)
echo "新临时账号: $USER2"

mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT user, host FROM mysql.user WHERE user='$USER2';"

echo "等 130 秒让 2m lease 过期..."
sleep 130

mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT COUNT(*) FROM mysql.user WHERE user='$USER2';"
# 应输出 0
```

---

## ✅ 验收

- [ ] `vault read database/creds/readonly` 返回 `username`、`password`、`lease_id`
- [ ] MySQL `mysql.user` 表中能看到临时用户
- [ ] 用临时账号能查询 `appdb.kv`
- [ ] `vault lease revoke` 后临时用户被 `DROP USER`
- [ ] 不主动 revoke，TTL 到期后临时用户也会消失
