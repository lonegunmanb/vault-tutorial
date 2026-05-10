# 实验说明

本实验使用 Killercoda 提供的 Kubernetes 单节点环境。后台脚本只安装 Vault CLI、Helm 与常用命令行工具；Secrets Store CSI driver、Vault dev server、Vault Secrets Store CSI provider，以及实验 namespace / ServiceAccount 都会在第一步由你执行安装与创建。

第一步会运行 `/root/configure-vault-csi.sh`，通过 Kubernetes Job 在 Vault 中配置 Kubernetes auth method、KV v2 机密 `secret/csi/app`、policy 与 Vault role `csi-app`，并生成后续步骤使用的 `/root/csi-file-mount.yaml`、`/root/csi-bad-sa.yaml`、`/root/csi-env-sync.yaml` 与 `/root/csi-env-app.yaml`。

你将依次完成四个任务：

1. 安装 Secrets Store CSI driver、Vault provider，创建实验身份，并检查 `SecretProviderClass` CRD。
2. 创建 `SecretProviderClass` 与 Deployment，把 Vault 机密挂载到 `/mnt/secrets-store`。
3. 使用未授权 ServiceAccount 触发挂载失败，观察 Vault role 与 Pod 身份的边界。
4. 使用 `secretObjects` 把同一份数据同步为 Kubernetes Secret，并通过 `secretKeyRef` 注入环境变量。

实验使用 KV v2 静态机密来聚焦 CSI 挂载链路。动态数据库凭据、证书 lease 与轮转策略会在后续数据库、PKI 与 VSO 章节继续展开。