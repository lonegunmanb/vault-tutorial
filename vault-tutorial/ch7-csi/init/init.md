# 实验说明

本实验使用 Killercoda 提供的 Kubernetes 单节点环境。后台脚本会完成以下准备工作：安装 Vault CLI 与 Helm，安装 Secrets Store CSI driver，使用 Vault Helm chart 安装一个 dev 模式 Vault Server 与 Vault Secrets Store CSI provider，并在 Vault 中预置 `secret/csi/app` 这条 KV v2 机密。

你将依次完成四个任务：

1. 检查 Secrets Store CSI driver、Vault provider 与 `SecretProviderClass` CRD。
2. 创建 `SecretProviderClass` 与 Deployment，把 Vault 机密挂载到 `/mnt/secrets-store`。
3. 使用未授权 ServiceAccount 触发挂载失败，观察 Vault role 与 Pod 身份的边界。
4. 使用 `secretObjects` 把同一份数据同步为 Kubernetes Secret，并通过 `secretKeyRef` 注入环境变量。

实验使用 KV v2 静态机密来聚焦 CSI 挂载链路。动态数据库凭据、证书 lease 与轮转策略会在后续数据库、PKI 与 VSO 章节继续展开。