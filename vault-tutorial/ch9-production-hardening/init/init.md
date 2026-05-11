# 实验说明

本实验配套 [9.1 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-production-hardening.html)：学员此时已经在概念层理解了"上线前安全加固清单分基线/扩展两层、覆盖进程身份、网络 TLS、操作系统隔离、令牌生命周期四个面向"，以及"请求速率限流配额按 path 限制每 interval 内的请求数、社区版始终按源 IP 分组、enable_rate_limit_audit_logging 控制被拒请求是否进入审计日志"这套机制。本实验把其中可观察的部分变成可在终端里直接复现的现象：

1. 创建一条针对 `transit` 引擎的速率限流（小阈值便于课堂复现），用 `for` 循环把加密请求量打到阈值之上，验证 Vault 立即返回带 `429` 的被拒响应；
2. 在 `sys/quotas/config` 上开启 `enable_rate_limit_audit_logging`、再次触发被拒，对比开关开/关两种状态下 file 审计日志中是否出现这些被拒请求；
3. 追加一条 `path` 留空的全局速率限流规则，验证它对所有请求（不限挂载点）生效，作为集群兜底。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成：

- 已安装 `vault`（1.19.2）、`jq`、`curl`；
- 已预置 `/root/vault.hcl`：单节点 raft 存储位于 `/opt/vault/data`，listener 绑定 `0.0.0.0:8200`、`tls_disable = true`；
- 已写入 `VAULT_ADDR=http://127.0.0.1:8200`；
- 已生成便捷脚本 `/root/start-vault.sh`、`/root/stop-vault.sh`。

> 本实验全程使用明文 HTTP，目的是让 `curl` 输出干净易读、便于直接观察响应；生产环境请按 9.1 节"基线 / 端到端 TLS"一段所述启用 TLS。同样，生产场景中速率限流的阈值通常远高于本实验所用的"每秒数次"，本实验把阈值设得很小是为了在终端里几秒钟之内就能复现被拒响应；请勿把课堂数值直接搬到生产环境。
