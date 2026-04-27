# 实验：LDAP 机密引擎的三种使用模式

[3.10 LDAP 机密引擎](/ch3-ldap) 讲清楚了 Vault 用一个管理员 `binddn` 操作 OpenLDAP 的总体模型，
以及三种模式（Static / Dynamic / Library）的差别。本实验在一个真实的 OpenLDAP 容器上把三种模式
全跑一遍，并从 LDAP 端用 `ldapsearch` 反向验证 Vault 的所有动作确实生效。

---

## 实验环境

后台脚本会自动准备好：

- **OpenLDAP** 容器（`osixia/openldap:1.5.0`），监听 `127.0.0.1:389`
  - Admin DN: `cn=admin,dc=example,dc=org`
  - Admin 密码: `admin`
  - Base DN: `dc=example,dc=org`
  - 预创建 OU：`ou=ServiceAccounts`、`ou=DynamicUsers`
  - 预置 Static 用账号：`app1` / `app2` / `app3`（初始密码 `initial-pass-{i}`）
  - 预置 Library 用账号：`svc-ops-1` / `svc-ops-2` / `svc-ops-3`（初始密码 `ops-initial-pass-{i}`）
- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- 工具：`ldap-utils`（`ldapsearch` / `ldapmodify`）、`jq`、`docker`

---

## 你将亲手验证的事实

1. Vault 用 `binddn` 改了 LDAP 账号的 `userPassword` 后，旧密码立刻失效、新密码立刻可用
2. Static Role 按 `rotation_period` 自动改密，应用读 `static-cred` 永远拿到当前有效密码
3. Dynamic Role 申领时按 `creation_ldif` 现场建账号，Lease 到期时按 `deletion_ldif` 销毁
4. Library Set 借出瞬间换密、归还瞬间再换密，旧借用人的密码用不了了

预期耗时：15 ~ 25 分钟（含 OpenLDAP 镜像拉取约 30 秒）。
