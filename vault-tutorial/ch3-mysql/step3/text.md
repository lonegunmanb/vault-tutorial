# 第 3 步：Wildcard grant —— base64 规避 shell 反引号

官方 MySQL/MariaDB 文档专门提醒：MySQL grant 语句里可以用通配符，例如授权所有 `fooapp_` 开头的数据库；但是通配部分要放在反引号里，直接贴到 shell 会被当成命令执行。所以本步按官方建议，把 creation statement base64 后再写入 Vault。

---

## 3.1 准备 wildcard SQL

```bash
cat >/tmp/wildcard.sql <<'SQL'
CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON `fooapp\_%`.* TO '{{name}}'@'%';
SQL

cat /tmp/wildcard.sql
```

这段 SQL 的含义是：Vault 每次生成一个新用户，然后只授予它读取所有 `fooapp_` 开头数据库的权限。

## 3.2 base64 后写入 Dynamic Role

```bash
WILDCARD_STMT=$(base64 -w 0 /tmp/wildcard.sql)
echo "$WILDCARD_STMT"

vault write database/roles/wildcard-role \
  db_name="mysql-main" \
  creation_statements="$WILDCARD_STMT" \
  revocation_statements="DROP USER '{{name}}'@'%';" \
  default_ttl="2m" \
  max_ttl="10m"
```

官方 API 页说明 `creation_statements` 可以是 base64 编码后的分号分隔字符串；这里正好用这个能力避开 shell 反引号。

## 3.3 申领 wildcard 凭据

```bash
WCRED=$(vault read -format=json database/creds/wildcard-role)
WUSER=$(echo "$WCRED" | jq -r .data.username)
WPASS=$(echo "$WCRED" | jq -r .data.password)
WLEASE=$(echo "$WCRED" | jq -r .lease_id)

echo "wildcard 用户: $WUSER"
```

## 3.4 验证只能读 `fooapp_` 开头的库

`fooapp_alpha.audit` 应该能读：

```bash
mysql -h 127.0.0.1 -u"$WUSER" -p"$WPASS" -Nse "SELECT * FROM fooapp_alpha.audit;"
```

`appdb.kv` 不匹配 `fooapp\_%`，所以应该失败：

```bash
mysql -h 127.0.0.1 -u"$WUSER" -p"$WPASS" -Nse "SELECT * FROM appdb.kv;" 2>&1 | head -3
```

## 3.5 清理 wildcard 用户

```bash
vault lease revoke "$WLEASE"

mysql -h 127.0.0.1 -uroot -prootpassword -Nse \
  "SELECT COUNT(*) FROM mysql.user WHERE user='$WUSER';"
# 应输出 0
```

---

## ✅ 验收

- [ ] `wildcard-role` 能成功写入 Vault
- [ ] 申领的用户能查询 `fooapp_alpha.audit`
- [ ] 同一个用户不能查询 `appdb.kv`
- [ ] revoke 后 wildcard 用户从 MySQL 中消失
