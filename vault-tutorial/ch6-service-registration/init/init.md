# 实验说明

本实验配套 [6.7 节正文](/ch6-service-registration)：学员此时已经在概念层理解了"`service_registration` 是与 `storage` 解耦的、用于把节点状态广播给外部服务发现系统的可选块"，本实验把其中几条核心结论做成可在终端里直接观察到的现象：

1. 即便存储后端选用 Raft，只要在 `vault.hcl` 中显式声明 `service_registration "consul"` 块，Vault 节点就会被注册进 Consul 服务目录；
2. Consul 据此对外暴露三个 DNS 端点：`active.vault.service.consul`（仅活跃节点）、`standby.vault.service.consul`（仅待命且已 unseal 节点）、`vault.service.consul`（全部已 unseal 节点）；
3. 处于 sealed 状态的节点会被 Consul 主动从健康池中剔除，因而从这三个 DNS 端点的解析结果中消失；
4. `service_tags` 与 `service_meta` 这两个参数能够把任意业务标签 / 元数据附加到注册条目上，便于上游系统按机房、版本、环境等维度筛选。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成。Consul 以 dev 模式（`consul agent -dev`）在 `127.0.0.1:8500` 启动，同时把 DNS 监听绑定在 `127.0.0.1:8600`，便于直接用 `dig` 查询。3 个 Vault 进程通过 `127.0.0.1` 上的不同端口隔离（API 8200/8210/8220、cluster 8201/8211/8221），存储后端使用 Integrated Storage（Raft），并各自加入指向 Consul 的 `service_registration "consul"` 块。

实验开始时，环境已完成下列准备：

- 已安装 `vault`（1.19.2）、`consul`（最新稳定版本）、`jq`、`curl`、`dnsutils`（提供 `dig`）；
- 已为 3 个 Vault 节点预置完整的 `vault.hcl`：
  - `/root/vault-1.hcl`：node-1，API 8200，cluster 8201，作为 bootstrap 节点（无 `retry_join`），含 `service_registration "consul" { address = "127.0.0.1:8500" }`；
  - `/root/vault-2.hcl`：node-2，API 8210，cluster 8211，通过 `retry_join` 指向 node-1，service_registration 同上；
  - `/root/vault-3.hcl`：node-3，API 8220，cluster 8221，通过 `retry_join` 指向 node-1，service_registration 同上；
- 已为每个节点预创建独立的 raft 数据目录 `/opt/vault/data-{1,2,3}`；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/`，登录 shell 自动加载；
- 已提供便捷脚本 `/root/start-node.sh <1|2|3>` 用于在后台启动指定 Vault 节点；以及 `/root/start-consul.sh` 用于启动 Consul dev agent。

> 本实验全程使用明文 HTTP（`tls_disable = true`）以简化观察。生产环境请按 6.2 节的基线启用 TLS，并按 6.7 节 §2.3 配置 Vault 与 Consul 之间的 `tls_*` 参数。
