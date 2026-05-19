# 实验说明

本实验在单台 Killercoda 主机上把 9.9 节描述的"网站 + Vault + OpenLDAP + TOTP"四件套搭起来，让你**亲手**走完从"新用户第一次登录会被锁在门外"到"用 enrollment 解开死循环"，再到"两阶段登录拿到 Token"的完整闭环。

环境会预先准备好：

- **dev 模式 Vault**：`VAULT_ADDR=http://127.0.0.1:8200`，root token = `root`；已启用 `file` 审计设备写到 `/var/log/vault-audit.log`；
- **OpenLDAP 容器**：监听 `localhost:389`，目录树根 `dc=learn,dc=example`；预创建一位真实用户 `cn=alice,ou=users,dc=learn,dc=example`，初始口令 `LdapPass!2026`；rootdn 为 `cn=admin,dc=learn,dc=example`、口令 `2LearnVault`；
- **Vault 这四块积木已经写好**（对应 9.9 §3）：
  - `auth/ldap` 已启用并连上 OpenLDAP；
  - `sys/mfa/method/totp/my-totp` 已创建，`method_id` 已写入 `/root/totp-method-id` 与 `/etc/profile.d/totp.sh`（环境变量 `TOTP_METHOD_ID`）；
  - `sys/mfa/login-enforcement/ldap-mfa-enforce` 已生效——所有 `auth/ldap/login` 都强制走 TOTP；
  - alice 的 **Identity Entity 与 entity-alias 已经预建好**（解了第 4 节里那个鸡生蛋）；**但 alice 还没有 TOTP 密钥**——这一步留到 step 2 由你来跑；
- **Go 网站源码**已落到 `/root/web-app/`（一个文件 `main.go` + `go.mod`，Go 标准库实现，约 300 行），background 脚本会把它编译成 `/root/web-app/app` 并以 `nohup` 起到 `:8080`；
- **辅助工具**：`oathtool`（在终端生成 TOTP 6 位码）、`ldap-utils`、`jq`、`curl` 已装好；
- **Killercoda 端口转发**：网页 tab 会自动暴露主机 `:8080`，等你在 step 3 用浏览器登录时直接点击即可。

你将依次完成四步：

1. **检查环境**：用 `vault read` / `vault list` / `ldapsearch` 把"四块积木 + alice + 还没有 TOTP"这几条事实逐一确认；
2. **复现死循环 + 跑通 enrollment**：先尝试用 alice 登录，看 Vault 返回 `mfa_requirement` 后没法继续；然后跑 enrollment 脚本调 `admin-generate`，把返回的 secret 注册进 `oathtool`；
3. **两阶段登录**：先在终端里手写 `curl` 把两步分别打一遍，再切到浏览器走一遍同样的流程；
4. **负面用例 + 审计日志**：故意输错 OTP、故意重用 `mfa_request_id`，然后到 `/var/log/vault-audit.log` 里把整个流程的结构化 JSON 翻出来。

> 实验不依赖任何外部网络或云资源，可以放心反复执行。
