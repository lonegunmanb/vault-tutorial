# 实验完成

你已经完成本节 Secrets Store CSI Driver 与 Vault Provider 实验，并验证了以下事实：

- `SecretProviderClass` 是 CSI provider 的核心声明对象。
- `provider: vault` 会把挂载请求交给 Vault Secrets Store CSI provider。
- `objects.objectName` 会成为挂载目录中的文件名。
- CSI provider 使用发起挂载的 Pod 的 ServiceAccount 身份登录 Vault。
- 未绑定到 Vault role 的 ServiceAccount 会在挂载阶段失败。
- `secretObjects` 可以把 Vault 数据同步为 Kubernetes Secret，再由 `secretKeyRef` 注入环境变量。

请保留本节的关键边界：CSI provider 适合按 Pod 生命周期挂载机密；如果后续希望由平台控制器持续协调 Vault 数据与 Kubernetes Secret，并触发工作负载滚动，请继续学习 Vault Secrets Operator。