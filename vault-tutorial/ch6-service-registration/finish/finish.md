# 实验完成

至此，学员完成了围绕 `service_registration "consul"` 块的四步实操：

1. 在 Raft 存储后端之上**显式**声明 `service_registration "consul"`，让 3 个 Vault 节点被注册进 Consul 服务目录；
2. 通过 `dig` 验证 `active.vault.service.consul` / `standby.vault.service.consul` / `vault.service.consul` 三个 DNS 端点各自精确对应的节点子集；
3. 主动 seal 一个待命节点，观察它在 Consul 健康检查更新后从两个 DNS 端点中"自动隐身"，并在 unseal 后再次出现；
4. 加入 `service_tags` 与 `service_meta` 后通过 Consul catalog API 与按 tag 的 DNS 查询验证自定义标签的端到端透传。

> **关于 Kubernetes 服务注册的延伸说明**：本实验未覆盖 `service_registration "kubernetes"`，因为该模式要求一个真实的 Kubernetes 集群与 Vault 进程在 Pod 内运行，无法在单台 Killercoda Ubuntu 主机上以同等清晰度演示。学员若希望把本实验的结论迁移到 Kubernetes 模式，关键差异在于：
> - "服务目录"从 Consul 换成 Kubernetes API server；
> - "DNS 端点"换成 Kubernetes Service 的 selector（按 `vault-active` 等标签筛选 Pod）；
> - 节点状态以 Pod label 的形式持续被 Vault 改写，因此 Vault 进程所属的 ServiceAccount 必须具备对自身 Pod 的 `get` / `update` / `patch` 权限。

> **生产环境补强提示**：
> - 与 Consul 的通信应启用 TLS（`scheme = "https"` 与 `tls_*` 系列参数）；
> - 若 Consul 启用了 ACL，需要为 Vault 单独签发具备 `service.vault: write` 权限的 ACL token，并通过 `token` 参数注入；
> - 客户端建议指向 `active.vault.service.consul`，把"找到当前活跃节点"这一职责完全下放给 Consul DNS，而不再依赖应用侧或负载均衡器自行判定。
