# 恭喜完成 LDAP 认证实验！

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| Step 1 | Vault 可以用 `binddn` 搜索 LDAP 用户和组，再为后续登录准备用户定位与组解析配置。 |
| Step 2 | LDAP 组 `dev`、`ops` 可以映射到 Vault policy，用户登录时会按组成员关系得到对应 policy。 |
| Step 3 | Vault 本地 user 映射只影响新签发的 token，旧 token 不会自动获得新增 policy。 |
| Step 4 | `userfilter` 可以根据 LDAP 用户属性缩小允许登录的人群，密码正确的用户也可能被过滤器排除。 |

## 和 LDAP 机密引擎的区别

```text
LDAP auth method:    LDAP 用户 + 密码 -> Vault token
LDAP secrets engine: Vault -> LDAP 账号密码管理
```

前者负责“让目录用户进 Vault”，后者负责“让 Vault 管理目录账号”。这两个方向都连接 LDAP，但职责完全不同。

## 三个最容易踩的坑

1. `binddn` 不是登录用户本身，而是 Vault 用来搜索用户和组的查询账号；登录用户的密码仍要单独通过 LDAP bind 验证。
2. 组名映射发生在 Vault 侧的 `auth/ldap/groups/<name>`，LDAP 里有组并不自动等于有 Vault 权限。
3. 修改 LDAP 组成员或 Vault 映射后，旧 Vault token 不会自动更新；需要吊销旧 token 并重新登录。

**返回文档**：[4.6 LDAP 认证](/ch4-ldap)