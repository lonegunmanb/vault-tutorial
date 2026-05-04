# 实验：LDAP 认证方法完整动手

[4.6 LDAP 认证](/ch4-ldap) 讲的是“LDAP 用户登录 Vault”的入站方向：用户提交 LDAP 用户名和密码，Vault 到 LDAP 里确认身份和组成员关系，然后签发带有 Vault policy 的 Vault token。

本实验使用一个真实的 OpenLDAP 容器，预置用户、组和一个 Vault 查询账号；你会亲手配置 `auth/ldap`，再用 `alice`、`bob`、`carol` 的 LDAP 密码登录 Vault，观察组映射、用户映射和 `userfilter` 的效果。

---

## 实验环境

后台脚本会准备好：

- OpenLDAP 容器：`ldap://127.0.0.1:389`
- Base DN：`dc=example,dc=org`
- 管理员（也用作 Vault `binddn` 查询账号，简化实验环境的 ACL 配置；生产环境应使用最小权限的专用查询账号）：`cn=admin,dc=example,dc=org` / `admin`
- 用户：`alice` / `alice-pass`、`bob` / `bob-pass`、`carol` / `carol-pass`
- 组：`dev` 包含 Alice 和 Bob，`ops` 包含 Alice，`contractors` 包含 Carol
- Vault Dev 模式：`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`

这些条目使用 OpenLDAP 常见的 `inetOrgPerson` 用户对象与 `groupOfNames` 组对象，便于用 `uid` 找用户、用 `member` 找组成员。

---

## 你将验证的事实

1. Vault 可以用一个低权限查询账号搜索 LDAP 用户和组，然后用用户自己的密码完成 bind 登录。
2. LDAP 组名可以映射到 Vault policy，用户登录时会得到对应 policy。
3. Vault 本地 user 映射只在 token 创建时生效，旧 token 不会因为映射变化自动获得新权限。
4. `userfilter` 可以在用户搜索阶段附加限制，例如拒绝 `employeeType=Contractor` 的账号登录。

预期耗时：15 ~ 25 分钟。