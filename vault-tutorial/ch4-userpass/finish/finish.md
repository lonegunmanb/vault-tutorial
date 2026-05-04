# 恭喜完成 Userpass 认证实验！

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| Step 1 | `vault auth enable userpass` 会启用默认路径 `auth/userpass/`。 |
| Step 2 | 用户名、密码和 token 参数直接写在 `auth/userpass/users/<username>` 下。 |
| Step 3 | CLI/API 登录成功后，token 在响应的 `auth.client_token` 中。 |
| Step 4 | 可以单独更新密码、更新 policies、删除用户；提交用户名会小写归一化。 |

## 记住这句话

```text
userpass = Vault 自己维护的本地 username/password 表 + 登录后签发 token 的规则
```

它启动快、容易理解，但不要把它误当成 LDAP/OIDC 目录集成。需要外部身份系统时，请选择对应 auth method。

**返回文档**：[4.8 Userpass 认证](/ch4-userpass)