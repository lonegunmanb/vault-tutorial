# 第 1 步：启用 ldap/ 引擎并连接 OpenLDAP

[3.10 §2](/ch3-ldap) 讲过：所有操作都从 `vault write ldap/config` 写入管理员凭据开始。
本步完成的事：

1. `vault secrets enable ldap`
2. `vault write ldap/config ...` 配置 OpenLDAP 连接参数
3. 用 `ldapsearch` 从 OpenLDAP 端验证 Vault 看得见预置账号

---

## 1.1 启用引擎

```bash
vault secrets enable ldap
vault secrets list | grep -E "Path|ldap"
```

应能看到 `ldap/    ldap    ...    n/a    n/a    ...`。

## 1.2 写入连接配置

```bash
vault write ldap/config \
  url="ldap://127.0.0.1:389" \
  binddn="cn=admin,dc=example,dc=org" \
  bindpass="admin" \
  userdn="ou=ServiceAccounts,dc=example,dc=org" \
  schema="openldap"
```

字段含义见 [3.10 §2.1](/ch3-ldap)。读回来验证（`bindpass` 不会回显，正常）：

```bash
vault read ldap/config
```

## 1.3 从 LDAP 端反查预置账号

OpenLDAP 容器在 `init/background.sh` 里已预创建好六个账号——三个 `app{1,2,3}`（给 step2 Static Role 用）
和三个 `svc-ops-{1,2,3}`（给 step4 Library Set 用）。

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=ServiceAccounts,dc=example,dc=org" \
  "(objectClass=inetOrgPerson)" cn
```

应能看到 6 个 `cn:` 行。

> **想掌握 root 凭据轮转？** 在生产里写完 `ldap/config` 后会立刻执行
> `vault write -f ldap/rotate-root`——之后**连 Vault 都不再持有原 admin 密码**。
> 在本实验里**不要执行**它（否则后续步骤的 ldapsearch 命令会找不到密码）。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `ldap/`
- [ ] `vault read ldap/config` 返回了 url / binddn / userdn 等字段
- [ ] `ldapsearch` 能列出 6 个预置账号
