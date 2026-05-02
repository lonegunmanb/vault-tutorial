# 第 2 步：Dynamic Role —— 现场建账号、psql 实连、Lease 一到自动销毁

模型：[3.14 §4](/ch3-postgres)。本步：

1. 创建 Dynamic Role `readonly`：每次申领时按 `creation_statements` 在 PG 内 `CREATE ROLE`
2. `vault read database/creds/readonly` 拿到一对 `username` / `password` + `lease_id`
3. 直接用这对凭据 `psql` 进 PG 并 `SELECT * FROM demo.kv`
4. `vault lease revoke <id>` 后，PG 上对应账号立刻消失
5. 第二次申领，让 Lease 自然过期，观察相同结果

---

## 2.1 创建 Dynamic Role

```bash
vault write database/roles/readonly \
  db_name="postgres-main" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
                       GRANT USAGE ON SCHEMA demo TO \"{{name}}\";
                       GRANT SELECT ON ALL TABLES IN SCHEMA demo TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL ON ALL TABLES IN SCHEMA demo FROM \"{{name}}\";
                         REVOKE USAGE ON SCHEMA demo FROM \"{{name}}\";
                         DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="2m" \
  max_ttl="10m"

vault read database/roles/readonly
```

> 注意 `db_name="postgres-main"` 必须等于 step 1 里 `database/config/<name>` 末段名。

> **Vault 占位符** `{{name}}` / `{{password}}` / `{{expiration}}` 由 Vault 在每次申领时填充，
> 注入数据库前不会与你写的 SQL 字面量冲突。

## 2.2 申领一份动态凭据

```bash
CRED=$(vault read -format=json database/creds/readonly)
echo "$CRED" | jq

USER=$(echo "$CRED" | jq -r .data.username)
PASS=$(echo "$CRED" | jq -r .data.password)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "临时账号: $USER"
echo "Lease ID: $LEASE"
```

`username` 形如 `v-token-readonly-xxxxx`——前缀 `v-` + 调用者类型 + role 名 + 随机串。

## 2.3 旁路：PG 端确认账号已建

```bash
PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='$USER';"
# 应输出 $USER
```

## 2.4 用临时账号实连 PG，跑 SELECT

```bash
PGPASSWORD="$PASS" psql -h 127.0.0.1 -U "$USER" -d postgres -c "SELECT * FROM demo.kv;"
# 应输出 demo.kv 的两行 hello/vault
```

> 如果这里报 `permission denied for schema demo`，说明当前环境里的 `vaultadmin` 只有读取权限，
> 但没有把权限转授给临时账号的 `WITH GRANT OPTION`。执行一次：
>
> ```bash
> PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -c "
> GRANT USAGE ON SCHEMA demo TO vaultadmin WITH GRANT OPTION;
> GRANT SELECT ON ALL TABLES IN SCHEMA demo TO vaultadmin WITH GRANT OPTION;"
> vault lease revoke "$LEASE"
> ```
>
> 然后回到 2.2 重新申领一份动态凭据。

## 2.5 Revoke Lease，验证账号被销毁

```bash
vault lease revoke "$LEASE"
sleep 1

PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname='$USER';"
# 应输出 0

PGPASSWORD="$PASS" psql -h 127.0.0.1 -U "$USER" -d postgres -c "SELECT 1;" 2>&1 | head -2
# 应输出: FATAL:  role "v-token-readonly-..." does not exist
```

## 2.6 第二次申领，观察 Lease 自然过期清理

```bash
CRED2=$(vault read -format=json database/creds/readonly)
USER2=$(echo "$CRED2" | jq -r .data.username)
LEASE2=$(echo "$CRED2" | jq -r .lease_id)
echo "新临时账号: $USER2 (Lease 2 分钟后自动过期)"

# 立刻能看到
PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='$USER2';"

echo "等 130 秒看 Lease 自动过期..."
sleep 130

PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname='$USER2';"
# 应输出 0 —— Vault 的 lease expiration manager 已经按 revocation_statements 删掉了
```

---

## ✅ 验收

- [ ] 申领后 `pg_roles` 里多出一条 `v-token-readonly-...`
- [ ] 用临时账号能 `SELECT * FROM demo.kv`
- [ ] `vault lease revoke` 后该账号从 `pg_roles` 消失，再用其密码登 PG 失败
- [ ] 不主动 revoke，TTL 到期后同样消失

> 与 Step 3 的 Static Role 形成对比：Dynamic 的账号 **每次申领都不一样**，密码与账号同生命周期；
> Static 的账号 **同一个**，只是密码周期变。
