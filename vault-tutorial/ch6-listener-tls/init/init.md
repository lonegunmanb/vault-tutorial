# 实验说明

本实验承接 6.1 节实验：你已经能用一份 `vault.hcl` 启动一个非 dev 模式的 raft 单节点 Vault。本实验在那份骨架之上，把 `listener "tcp"` 块从默认的 `tls_disable = true` 一步步升级到**仅接受 TLS 1.3**的强化基线，并验证若干官方文档中明确强调的边界行为。

实验开始时，环境已为你完成下列准备：

- 安装好 `vault` 命令；
- 安装好 `openssl`、`jq`、`sslscan`、`curl` 等辅助工具；
- 在 `/root/vault.hcl` 中预置一份**禁用 TLS** 的最小配置文件；
- 创建数据目录 `/opt/vault/data` 与 TLS 证书目录 `/etc/vault.d/tls`；
- 把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/vault.sh`，在升级到 HTTPS 后会让你手动改成 `https://...`。

Vault 进程**尚未**启动；请按照后续步骤亲手启动并完成 TLS 强化。
