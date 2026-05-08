# 实验完成

恭喜你完成本节实验。本节同时演示了 `service_registration` 的两种官方实现，每一种都把 6.7 节正文中相应的概念落到了可观察的现象上：

**Consul 模式（step 1 ~ step 2）**

1. 在 Raft 存储后端之上**显式**声明 `service_registration "consul"` 块，让 3 个 Vault 节点被注册进 Consul 服务目录；
2. 通过 `dig` 验证 `active.vault.service.consul` / `standby.vault.service.consul` / `vault.service.consul` 三个 DNS 端点各自精确对应的节点子集；
3. 主动 seal 一个待命节点，观察它在 Consul 健康检查更新后从两个 DNS 端点中自动隐身，与正文 §2.2 关于"sealed 节点会被 Consul 主动剔除"的描述完全一致。

**Kubernetes 模式（step 3 ~ step 4）**

1. 用官方 `hashicorp/vault` Helm chart 在 K8s 上部署 3 副本 HA Vault，chart 默认就把 `service_registration "kubernetes" {}` 块、Downward API 注入与 ServiceAccount RBAC 三件事帮你配齐；
2. 在 `kubectl get pod -L vault-active,vault-sealed,...` 的输出里直接看到 Vault 把节点状态写到自身 Pod label 上；
3. 主动 `kubectl delete pod` 杀掉当前 leader 触发重新选举，观察标签随之翻转、Helm chart 默认创建的 `vault-active` Service 的 endpoints 自动迁移到新 leader——一条"内部 HA 状态 → label → selector → endpoints"的完整链路。

把两种模式横向放在一起回看 6.7 节正文 §4 的"心智地图"：

- **Consul 模式提供的是"DNS 视角"**——客户端只需查询一个 DNS 名（例如 `active.vault.service.consul`）就能被指向当前 leader；
- **K8s 模式提供的是"Label 视角"**——客户端只需用一个固定的 Service 名就能被指向当前 leader，路由由 Pod label + Service selector 完成；
- 两种模式对应用代码而言都是"纯透明"的，运维人员真正要做的事只有：在 `vault.hcl` 中声明意图、为 Vault 准备相应的访问凭据（Consul ACL token / K8s ServiceAccount 与 RBAC）、把存储后端换成 raft 之外的任意后端时**记得显式带上** `service_registration` 块。

> **生产环境补强提示**：
> - 与 Consul 通信请启用 TLS（`scheme = "https"` + `tls_*` 系列参数）；若 Consul 启用了 ACL，需为 Vault 单独签发具备 `service.vault: write` 权限的 token，并通过 `token` 参数注入。
> - K8s 模式下，本实验为简化演示在 chart 中关闭了 anti-affinity（`affinity: ""`）、并使用了 1/1 分片；生产请保留 chart 默认的 anti-affinity 让 3 副本分散到不同 worker、并改用 5/3 等更稳健的 Shamir 配置。
> - K8s `vault-active` Service 的 endpoints 会随选举立刻翻转，但客户端连接池里**老的连接不会立刻自动切换**——结合 `publishNotReadyAddresses: false` 让失败 Pod 立即被踢出端点池，并在客户端侧设置较短的连接保活时间，能把切换感知度做到秒级。
