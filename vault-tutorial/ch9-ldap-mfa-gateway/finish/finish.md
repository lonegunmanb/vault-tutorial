# 实验完成

你已经在一台主机上把 Vault OSS 版“网站把 LDAP + TOTP 登录托管给 Vault”跑通了：

- `auth/ldap` 负责把网站提交的用户名/密码转交给 OpenLDAP 做 simple bind；
- `totp` secrets engine 负责保存 alice 的 TOTP seed，并在 `totp/code/alice` 校验 6 位验证码；
- 网站后端自己维护 pending session：第一阶段 token 先扣住，第二阶段 `valid=true` 后才升级为正式登录态；
- enrollment 用高权限 token 创建 `totp/keys/alice`，日常登录 token 只有 `totp/code/alice` 的验证权限；
- 错 OTP、重放 OTP、主动 revoke 与审计日志都被你验证过。

## 你掌握的要点

- `sys/mfa` Login MFA 是 Enterprise 自动拦截方案；Vault OSS 可以用 LDAP auth + TOTP secrets engine 做网站级手工编排；
- 第一阶段 LDAP token 只是 pending token，不等于网站登录完成；
- `totp/keys/*` 是 enrollment 管理面，`totp/code/*` 是登录验证面，权限要拆开；
- 浏览器永远不要直接拿 Vault token，只拿网站自己的 `sid` Cookie；
- OTP 失败、pending 超时、登出都应该主动 `revoke-self`；
- audit device + rate limit quota 才是生产化登录防线的下一层。

## 生产化的下一步

- 把 enrollment 从 shell 脚本封装成真正的 Web 服务，用一次性邀请链接 + 短 TTL enrollment token 收敛权限；
- 用第 6.5 章的 LDAPS / TLS 把 Vault 到 OpenLDAP 之间的明文流量加密；
- 给 `auth/ldap/login` 和网站 `/mfa` 做 rate limit，挡住密码暴力破解与 OTP 穷举；
- 把 audit log 接到告警链路，例如同一 IP 连续 OTP 失败时触发告警；
- 如果生产环境有 Vault Enterprise，可以把网站手工编排替换为 `sys/mfa/login-enforcement` 的自动 Login MFA。