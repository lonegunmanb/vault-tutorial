# 实验说明

本实验承接 6.1 节实验：学员此时已具备使用一份 `vault.hcl` 启动非 dev 模式 raft 单节点 Vault 的能力。本实验在该骨架之上，将 `listener "tcp"` 块从默认的 `tls_disable = true` 逐步升级至**仅接受 TLS 1.3**的强化基线，并验证若干官方文档中明确强调的边界行为。

实验开始时，环境已完成下列准备：

- 已安装 `vault` 命令；
- 已安装 `openssl`、`jq`、`sslscan`、`curl` 等辅助工具；
- 已在 `/root/vault.hcl` 中预置一份**禁用 TLS** 的最小配置文件；
- 已创建数据目录 `/opt/vault/data` 与 TLS 证书目录 `/etc/vault.d/tls`；
- 已将 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/vault.sh`；升级到 HTTPS 后需要由学员手动修改为 `https://...`。

Vault 进程**尚未**启动；请依照后续步骤手动启动并完成 TLS 强化。
