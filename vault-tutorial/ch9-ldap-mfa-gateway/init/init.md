# 实验说明

本实验在单台 Killercoda 主机上把 9.9 节描述的 OSS 版“网站 + Vault + OpenLDAP + TOTP”搭起来。这里不使用 Enterprise-only 的 `sys/mfa` Login MFA，而是让网站后端自己编排两阶段登录：先让 Vault LDAP auth 校验密码并暂存 token，再让 Vault `totp` secrets engine 校验 OTP，最后才把 token 升级为网站登录态。

环境会预先准备好：

- **dev 模式 Vault**：`VAULT_ADDR=http://127.0.0.1:8200`，root token = `root`；已启用 `file` 审计设备写到 `/var/log/vault-audit.log`；
- **OpenLDAP 容器**：监听 `localhost:389`，目录树根 `dc=learn,dc=example`；预创建用户 `cn=alice,ou=users,dc=learn,dc=example`，初始口令 `LdapPass!2026`；
- **Vault 基础配置**：`auth/ldap` 已连上 OpenLDAP；`totp` secrets engine 已启用；alice 的 Identity Entity、LDAP alias 与 `alice-totp-login` policy 已建好；
- **故意留白**：`totp/keys/alice` 尚未创建，`/root/alice-totp-secret` 也不存在，这一步留到 step 2 的 enrollment；
- **Go 网站**：源码在 `/root/web-app/`，background 脚本会编译成 `/root/web-app/app` 并以 `nohup` 启到 `:8080`；
- **辅助工具**：`oathtool`、`ldap-utils`、`jq`、`curl` 已装好。

你将依次完成四步：

1. **检查环境**：确认 LDAP、`totp` 引擎、alice policy/entity、网站与审计设备；
2. **复现未绑定状态 + enrollment**：看到“密码正确但没有 TOTP key”时无法完成第二阶段，然后创建 `totp/keys/alice`；
3. **两阶段登录**：用 curl 和浏览器分别跑通“pending token → TOTP valid → 正式 session”；
4. **负面用例 + 审计日志**：验证错误 OTP、TOTP code 重放，以及 audit log 中的结构化记录。

> 实验不依赖任何外部云资源，可以放心反复执行。