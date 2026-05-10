# 实验说明

本实验在 Killercoda 提供的 Kubernetes 单节点环境中完成。后台脚本只安装 Vault CLI、Helm 与常用命令行工具；Vault dev server、Vault Secrets Operator (VSO)，以及 `vso-demo` namespace / `vso-app` ServiceAccount 都会在第一步由你执行安装与创建。

第一步会运行 `/root/configure-vault-vso.sh`，通过 Kubernetes Job 在 Vault 中配置 Kubernetes auth method、KV v2 机密 `secret/vso/app`、policy 与 Vault role `vso-app`，并生成后续步骤使用的 `VaultConnection`、`VaultAuth`、`VaultStaticSecret` 与应用 Deployment 清单。

你将依次完成四个任务：

1. 安装 Vault 与 VSO，创建实验身份，并检查控制器 Pod、相关 CRD 与 Vault 内的 KV / auth 配置是否就绪。
2. 创建 `VaultConnection` 与 `VaultAuth(kubernetes)`，让 VSO 能以 `vso-app` ServiceAccount 身份登录 Vault。
3. 创建 `VaultStaticSecret`，把 `secret/vso/app` 同步为 `vso-demo` 命名空间下的 Kubernetes Secret；让一个 Deployment 通过 `envFrom` 直接消费；更新 KV 数据，观察 Secret 在 `refreshAfter` 周期内被刷新。
4. 在 `VaultStaticSecret` 上增加 `rolloutRestartTargets`，再次更新 KV，观察 Deployment 被 VSO 自动滚动重启。

实验聚焦 KV v2 静态机密的同步链路与滚动触发机制。`VaultDynamicSecret`、`VaultPKISecret` 与 client cache 加密会在后续 7.7 节继续展开；事件驱动的 instant updates 仅在 Vault Enterprise 1.16.3+ 提供，本实验不涉及。
