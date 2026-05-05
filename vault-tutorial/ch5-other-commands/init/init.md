# 实验：lease / unwrap / ssh / path-help 重要命令

本实验会把四组不属于普通 CRUD 的重要命令放在同一个环境中练习：

- `vault path-help`：查看当前 Vault 路由中某条路径的内置帮助
- `vault lease lookup/renew/revoke`：查询、续期和撤销动态机密租约
- `vault unwrap`：取出 response wrapping token 中封装的响应
- `vault ssh`：通过 SSH 机密引擎生成登录凭据

实验环境已预先准备：

- Vault dev server，root token 固定为 `root`
- PostgreSQL 容器 `learn-postgres`，用于生成可续期的动态数据库凭据
- `database/` 机密引擎和 `readonly` 角色，`default_ttl=2m`，`max_ttl=10m`
- `ssh-otp/` 机密引擎和 `training-otp` 角色，用于演示 `vault ssh -mode=otp` 登录目标容器
- `jq`，用于在步骤中读取和整理 JSON 输出
- 本机 `ssh` 与支持 `-e` 的 `sshpass` 兼容命令，用于自动完成 SSH OTP 登录
- 预构建的 `ghcr.io/lonegunmanb/vault-tutorial-otp-ssh-ubuntu` 镜像，已内置 `vault-ssh-helper`、PAM 与 sshd 配置，第五步直接 `docker run` 启动即可

建议按步骤顺序执行。每一步都可以反复练习；如果你主动撤销了某条租约，只需重新读取 `database/creds/readonly` 即可生成新的动态凭据。