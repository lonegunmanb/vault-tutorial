# 实验：Userpass 认证完整动手

[4.8 Userpass 认证](/ch4-userpass) 讲的是 Vault 内置用户名密码登录。用户条目直接配置在 `auth/userpass/users/<username>` 下，登录成功后 Vault 按用户条目上的 token 参数签发 token。

---

## 实验目标

你将亲手完成：

1. 启用 `auth/userpass`。
2. 创建 `alice`、`bob`、`Mary` 三个用户，并绑定不同 token policy。
3. 分别用 CLI 和 API 登录，查看 `auth.client_token` 与 policy。
4. 验证用户名会被小写归一化。
5. 更新密码、更新 policy、删除用户并清理 auth method。

预期耗时：10 ~ 15 分钟。