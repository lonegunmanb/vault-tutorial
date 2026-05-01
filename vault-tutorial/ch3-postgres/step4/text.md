# 第 4 步：进阶 —— `scram-sha-256` 与 `allowed_roles` 多 role 隔离

[3.14 §3.1](/ch3-postgres) 把 `password_authentication="scram-sha-256"` 与 `allowed_roles` 列在了
`database/config/<name>` 字段表里。本步动手验证它们的实际效果。

---

## 4.1 验证 `scram-sha-256` 在 PG 端的实际效果

step 1 已经把 `password_authentication="scram-sha-256"` 写进连接配置。现在用超级用户旁路查
`pg_authid` 看 step 2 / step 3 中创建出来的密码到底以什么形式落库：

```bash
PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -c "
SELECT rolname,
       substring(rolpassword from 1 for 24) AS rolpassword_prefix
FROM pg_authid
WHERE rolname = 'legacy_app'
   OR rolname LIKE 'v-token-readonly-%'
   OR rolname = 'vaultadmin'
ORDER BY rolname;
"
```

应能看到所有由 Vault 写入的密码字段都以 `SCRAM-SHA-256$` 开头（前缀含算法名 + 迭代次数）：

```
        rolname         |    rolpassword_prefix
------------------------+--------------------------
 legacy_app             | SCRAM-SHA-256$4096:...
 vaultadmin             | SCRAM-SHA-256$4096:...
```

> `rolpassword` 是哈希值（不是明文）；Vault 通过 PG 的 `ALTER USER ... PASSWORD` 写入，PG 按当前 `password_encryption`
> 设置（PG 16 默认 `scram-sha-256`，且我们在连接配置上显式声明了）做哈希后落盘。
>
> 含义：即便 PG 的物理文件被复制走，离线也无法直接拿到明文密码——必须经过 SCRAM challenge-response 才能登入。

## 4.2 验证 `allowed_roles` 通配符

step 1 写入的 `allowed_roles="my-role,readonly,svc-*"`：

- 精确匹配：`my-role`、`readonly`
- 通配匹配：`svc-*`（任何以 `svc-` 开头的 role 名）

新建一个名字以 `svc-` 开头的 Dynamic Role：

```bash
vault write database/roles/svc-billing \
  db_name="postgres-main" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
                       GRANT USAGE ON SCHEMA demo TO \"{{name}}\";
                       GRANT SELECT ON ALL TABLES IN SCHEMA demo TO \"{{name}}\";" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="2m" \
  max_ttl="10m"

# 申领应成功
vault read database/creds/svc-billing | head -8
```

再试一个 **不被允许** 的 role 名 `analytics`（既不是精确匹配，也不匹配 `svc-*`）：

```bash
vault write database/roles/analytics \
  db_name="postgres-main" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
  default_ttl="2m" \
  max_ttl="10m"

# 这一步本身不会报错：role 创建只是把元数据写进 Vault；
# 真正的拒绝发生在尝试申领凭据时
vault read database/creds/analytics 2>&1 | head -3
# 应输出类似:
#   Error reading database/creds/analytics: Error making API request.
#   Code: 400. Errors:
#   * "analytics" is not an allowed role
```

> **设计含义**：`allowed_roles` 是连接级"安全围栏"——同一个 PG 实例下，
> 你可以用多条 `database/config/<...>` + 互不重叠的 `allowed_roles` 列表实现 **按租户/团队隔离**：
> 即便误把某个 role 挂错连接，凭据申领那一刻就会被拒，不会真的污染到 PG 端。

## 4.3 清理 `analytics` 这条非法 role

```bash
vault delete database/roles/analytics
```

---

## ✅ 验收

- [ ] `pg_authid.rolpassword` 中 Vault 写入的密码以 `SCRAM-SHA-256$` 开头
- [ ] `svc-billing`（匹配 `svc-*` 通配）能成功 `vault read database/creds/svc-billing`
- [ ] `analytics`（不在 allowed_roles 中）申领时报 `not an allowed role`

> **小结**：本节四步把开源版 `postgresql-database-plugin` 能跑的核心场景都跑了一遍。
> 企业版独有的 [Rootless Configuration](/ch3-postgres#6-rootless-configuration-每个-static-role-自带一条独立连接-enterprise) 与
> 需要真实云资源的 [GCP CloudSQL IAM](/ch3-postgres#72-gcp-cloudsql-iam-auth_typegcp_iam) 见正文 §6 §7.2。
