# 实验说明

本实验配套 [6.7 节正文](/ch6-service-registration)。学员此时已经在概念层理解了 `service_registration` 块"与 `storage` 解耦、把节点状态广播给外部服务发现系统"这一定位，本实验把正文中**两种实现**——Consul 集成模式与 Kubernetes 原生发现模式——分别落到可观察的现象上：

1. **Consul 模式**：在 Raft 存储后端之上**显式**声明 `service_registration "consul"` 块后，3 个 Vault 节点会被注册进 Consul 服务目录；
2. **Consul DNS 三端点**：`active.vault.service.consul`、`standby.vault.service.consul`、`vault.service.consul` 三条 DNS 名各自对应不同的节点子集；sealed 节点会被 Consul 健康检查主动剔除而"自动隐身"；
3. **Kubernetes 模式**：声明 `service_registration "kubernetes" {}` 后（官方 Helm chart HA + raft 模式默认就会写入这一行），Vault 进程会**反向把状态打到自己所在 Pod 的 label 上**——vault-active、vault-sealed、vault-initialized、vault-perf-standby、vault-version；
4. **K8s Service selector 跟随**：Helm chart 默认创建的 vault-active Service 用 `selector: vault-active=true` 选 Pod，因此其 endpoints 始终精确指向当前的 leader Pod，且会随重新选举自动迁移。

为了在同一台 Killercoda 主机上同时演示两种模式，本实验运行在 Killercoda 的 `kubernetes-kubeadm-1node` 环境中：

- **前 2 步**使用宿主机普通进程演示 Consul 模式：宿主机 Consul agent 监听 `127.0.0.1:8500`（HTTP）与 `127.0.0.1:8600`（DNS），3 个 Vault 进程通过 `127.0.0.1` 上的不同端口隔离（API 8200/8210/8220、cluster 8201/8211/8221），存储后端使用 Integrated Storage（Raft）。
- **后 2 步**通过官方 `hashicorp/vault` Helm chart 把 3 副本 HA Vault 部署到 K8s。在 step 3 开头会显式停掉宿主机的 3 个 Vault 进程以避免与 K8s 部署争抢资源；Consul agent 与 K8s 演示无关，可以保留也可以一起停掉。

实验开始时，环境已完成下列准备：

- 已安装 `vault`（1.19.2）、`consul`（最新稳定版本）、`helm`、`kubectl`、`jq`、`curl`、`dnsutils`（提供 `dig`）；
- 已为 3 个宿主机 Vault 节点预置完整的 `vault.hcl`：
  - `/root/vault-1.hcl`：node-1，API 8200，cluster 8201，作为 bootstrap 节点，含 `service_registration "consul" { address = "127.0.0.1:8500" }`；
  - `/root/vault-2.hcl`：node-2，API 8210，cluster 8211，通过 `retry_join` 指向 node-1；
  - `/root/vault-3.hcl`：node-3，API 8220，cluster 8221，通过 `retry_join` 指向 node-1；
- 已为每个节点预创建独立的 raft 数据目录 `/opt/vault/data-{1,2,3}`；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 与 `KUBECONFIG` 写入 `/etc/profile.d/`，登录 shell 自动加载；
- 已提供便捷脚本 `/root/start-consul.sh`、`/root/start-node.sh` `<1|2|3>`、`/root/stop-host-vaults.sh`；
- 已为 K8s 节点去除 `node-role.kubernetes.io/control-plane` 的 NoSchedule taint，使 Vault Pod 可被调度；
- 已添加 `hashicorp` Helm 仓库并执行 `helm repo update`；
- 已通过 `crictl` 在后台预拉 `hashicorp/vault:1.19.2` 镜像以缩短 step 3 的等待时间。

> 本实验全程使用明文 HTTP（`tls_disable = true`）以简化观察。生产环境请按 6.2 节启用 TLS，并按 6.7 节 §2.3 配置 Vault 与 Consul 之间的 `tls_*` 参数。
