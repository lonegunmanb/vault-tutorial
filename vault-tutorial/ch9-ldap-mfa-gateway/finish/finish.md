# 实验完成

你已经在一台主机上把 9.9 节描述的"网站把登录整段下沉给 Vault"跑通了：

- **四块积木** 都亲手摸了一遍：`auth/ldap` 让 Vault 能 bind LDAP、`sys/mfa/method/totp/my-totp` 定义了"TOTP 这一种 MFA"、`sys/mfa/login-enforcement/ldap-mfa-enforce` 把它强制到 LDAP 登录路径上、`admin-generate` 给 alice 生成了她那份独有的 TOTP 密钥；
- **死循环** 的破解办法被你亲手跑了一次：管理员**显式**为新用户建 Entity + alias，再调 `admin-generate` —— 在生产里就是封装成 enrollment service 那一段；
- **两阶段登录** 在 curl 和浏览器两种视角下各跑了一次；网站后端只发了两条 HTTP 请求，自己从来不连 LDAP、也从来不算 TOTP；
- **三类反例** 都验过：错 OTP 被拒、重用 `mfa_request_id` 被拒、临时去掉 enforcement 后第一阶段直接出 token；
- **审计日志** 里所有 `auth/ldap/login` 和 `sys/mfa/validate` 都留了结构化记录，足够做事后取证。

## 你掌握的要点

- Vault Login MFA 把登录切成两段 HTTP 调用的协议骨架，以及网站后端如何用服务端 session 串起两次调用；
- method ID（UUID）在 `mfa_payload` 里是必须的，"好记名字" `my-totp` 不行；
- `mfa_request_id` 一次性 + 短期，所以 OTP 输错必须回 `/login` 重走第一阶段；
- 新用户的"先有 Entity 才能有 TOTP 密钥"是 Login MFA 的固有约束，由 enrollment service 显式破解，**不要**让日常登录路径背这个权限；
- Vault Token 不能写进浏览器 Cookie；要主动 `revoke-self` 关掉 session；
- 审计设备 + rate limit quota 才是 MFA 之外真正能上生产的最小补丁。

## 生产化的下一步

- 把 enrollment 从一段 shell 脚本封装成一个真正的 Web 服务，用一次性邀请链接 + 短 TTL 的 enrollment token 收敛权限；
- 用第 6.5 章的 LDAPS / TLS 把 Vault 到 OpenLDAP 之间的明文流量加密；
- 给 `auth/ldap/login` 配 `Login Enforcement` 的同时，再配一条 9.1 节里讲的 **rate limit quota**，挡住密码暴力破解；
- 把审计日志接到 9.5 节的告警链路，"同一个 IP 5 分钟内 mfa/validate 失败 10 次"应该立刻触发告警；
- 不止 TOTP：Vault 还内置了 Duo / Okta / PingID 等 MFA 方法（开源版可用 TOTP；其他方法部分需 Enterprise），可以根据合规要求换底；
- 如果你的网站本身已经接了 OIDC（如 9.7 节的 Vault 作 OIDC Provider 案例），可以把"Vault 作 OIDC Provider + Login MFA"叠起来用，登录页直接复用 Vault 的——不用再写本节这个最小 Go 网站了。
