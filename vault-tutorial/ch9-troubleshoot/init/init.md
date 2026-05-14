# 实验说明

本实验配套 [9.5 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-troubleshoot.html)：学员此时已经在概念层理解了 Vault 把可观测性数据划分为"服务器日志、CLI / API 输出、UI 警告、审计设备、遥测指标"五类、以及"取证—推理—修复"这条主线。本实验把其中三个最具教学价值的故障情景搬到终端里直接复现：

1. **情景一：服务器启动失败** — 用一份**故意漏掉 `cluster_addr`** 的 raft 配置去启动 Vault，systemctl 报一句没有细节的 "Job for vault.service failed"，运维必须按提示走到 `journalctl -u vault.service` 才能读出根因 `Cluster address must be set when using raft storage`，补上一行 `cluster_addr` 后重启即恢复。
2. **情景二：客户端协议不匹配** — 启动一个**明文 HTTP** 的 dev 模式 Vault；在新终端**故意不导出 `VAULT_ADDR`**、直接 `vault status`，CLI 默认按 HTTPS 去连，会得到 `http: server gave HTTP response to HTTPS client` 的报错。修复方案恰恰**就藏在 dev 服务器的启动输出里**——`export VAULT_ADDR='http://127.0.0.1:8200'`。
3. **情景三：策略权限不足** — 在一台正常运行的 Vault 上启用 file 审计设备、挂载一个 KV 引擎、写一条**故意漏掉 `list` capability** 的策略，用基于该策略派生的 token 去 LIST，得到 `permission denied`；然后从审计日志里 grep 出对应条目，**亲眼看到** `"policy_results": { "allowed": false }`、`"operation": "list"` 等关键字段，再用 `vault policy read` 对照策略原文确认根因，补上 `list` 后重新登录拿到新 token，再次 LIST 成功。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成：

- 已安装 `vault`（1.19.2）、`jq`、`curl`；
- 已预置 `/root/vault-broken.hcl`：raft 存储 + listener 但**故意漏掉 `cluster_addr`**，用于情景一；
- 已预置 `/root/vault-fixed.hcl`：在前者基础上加上 `cluster_addr`，用于情景一修复后启动；
- 已写好便捷脚本 `/root/start-vault.sh`、`/root/stop-vault.sh`；
- 各情景之间相互独立，每一步都从干净状态开始。

> 本实验全程使用明文 HTTP，目的是让 `curl` 与 `vault` 命令的输出干净易读、便于直接观察响应；生产环境请按 [9.1 节](https://lonegunmanb.github.io/vault-tutorial/ch9-production-hardening.html) 所述启用端到端 TLS。同样，本实验把日志级别保持为 `info` 默认值，仅在需要演示 SIGHUP 动态切换时临时调高。
