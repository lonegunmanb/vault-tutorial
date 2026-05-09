# 实验完成

你已经完成本节 Vault Secrets Operator 实验，并验证了以下事实：

- VSO 是集群级常驻控制器；它通过 `secrets.hashicorp.com/v1beta1` API group 下的 CRD 工作。
- `VaultConnection` 描述如何连到 Vault；`VaultAuth` 描述以何种身份登录；二者都是同步类 CRD 的基础资源。
- `VaultAuth.spec.kubernetes.serviceAccount` 必须位于消费机密资源所在的 Kubernetes namespace，禁止跨 namespace 借用身份。
- `VaultStaticSecret` 把 Vault KV v2（或 KV v1）数据按 `refreshAfter` 周期刷新到原生 Kubernetes Secret 中。
- 默认开启的 `hmacSecretData` 让 VSO 能比对 Secret 是否真正变化，从而避免无意义的覆写与误触发。
- `rolloutRestartTargets` 通过给目标资源的 pod template 添加 `vso.secrets.hashicorp.com/restartedAt` annotation 触发标准 rollout-restart；支持的目标类型是 `Deployment`、`DaemonSet`、`StatefulSet`、`argo.Rollout`。
- Vault 短暂不可达时，已经物化的 Kubernetes Secret 仍可被 Pod 正常消费；只是控制器无法继续协调下一次刷新。

下一节将基于同一组 CRD 进入 `VaultDynamicSecret` 与 `VaultPKISecret` 的进阶用法：让 VSO 把动态数据库凭据与短 TTL 证书也以声明式方式同步进 Kubernetes。
