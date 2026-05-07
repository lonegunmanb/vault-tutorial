# 实验说明

本实验承接 [6.4 节正文](/ch6-integrated-storage)：学员此时已具备使用一份 `vault.hcl` 启动非 dev 模式 raft 单节点 Vault 的能力（6.1 节），并已掌握 listener TLS 强化与 auto-unseal 的基本操作（6.2 / 6.3 节）。本实验在该骨架之上，把单节点 Raft 扩展为 3 节点 Raft 集群，并把 Autopilot 的两条核心能力——Server Stabilization Time 与 Dead Server Cleanup——以可观察的方式跑通；最后在严格的"零真实云、零企业版授权"约束下，复现一次 quorum 永久丢失的故障，并通过 `peers.json` + raft snapshot 把数据完整恢复出来。

由于本课程严格限定在零真实云成本的条件下完成全部动手部分，本实验**采用单台 Killercoda 主机以端口区分启动 4 个 Vault 进程**——节点之间通过 `127.0.0.1` 上的不同端口完成 join 与 mTLS 通信，这与官方 [Integrated Storage Autopilot tutorial](https://developer.hashicorp.com/vault/tutorials/raft/raft-autopilot) 的本地多节点演示思路完全一致。

实验开始时，环境已完成下列准备：

- 已安装 `vault`（1.19.2）与 `jq`；
- 已为 4 个节点预置完整的 `vault.hcl`：
  - `/root/vault-1.hcl`：node-1，API 端口 8200，cluster 端口 8201，作为 bootstrap 节点（不带 `retry_join`）；
  - `/root/vault-2.hcl`：node-2，API 端口 8210，cluster 端口 8211，通过 `retry_join` 指向 node-1；
  - `/root/vault-3.hcl`：node-3，API 端口 8220，cluster 端口 8221，通过 `retry_join` 指向 node-1；
  - `/root/vault-4.hcl`：node-4，API 端口 8230，cluster 端口 8231，通过 `retry_join` 指向 node-1（仅在 Step 2 启动）；
- 已为每个节点预创建独立的 raft 数据目录 `/opt/vault/data-{1,2,3,4}`；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/`，登录 shell 自动加载；
- 已生成便捷启动脚本 `/root/start-node.sh`，用法 `./start-node.sh <1|2|3|4>`，在后台启动指定节点并把日志写到 `/var/log/vault-N.log`。

本实验的全部 Vault 进程**均尚未启动**；请依照后续步骤逐一手动启动。

> 本实验全程使用明文 HTTP（`tls_disable = true`），目的是把学员注意力集中在 Raft 与 Autopilot 行为上，而非 listener TLS。生产环境必须按 6.2 节的基线启用 TLS。
