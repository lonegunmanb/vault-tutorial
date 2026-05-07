# 实验完成

恭喜你完成本节实验。在本实验中，你已经：

- 在单台 Killercoda 主机上以端口隔离启动了一个 3 节点 Vault Raft 集群（API 8200/8210/8220、cluster 8201/8211/8221），并通过 `sys/leader` API 区分了 active 与 standby 节点；
- 在不做任何额外配置的前提下向 standby 节点发起了 KV 读取请求，从 CLI 与 `curl -i` 两个角度确认 standby 默认就把请求**透明转发**到了 active，客户端只看到 `200 OK`；
- 通过 `X-Vault-No-Request-Forwarding: 1` 请求头复现了底层的 `307` 重定向行为，并对比 `Location` 头与 `sys/leader.leader_address`，确认重定向目标正是 active 节点配置的 `api_addr`；
- kill 掉当前 leader 触发 Raft 重新选举，验证新 leader 在剩余两节点间产生，且转发路径与重定向路径都自动跟随新 leader 迁移、数据完整保留。

至此，6.5 节正文里"活跃节点抢锁、待命节点转发或重定向、`api_addr` 与 `cluster_addr` 各司其职"这一组核心概念已经从纸面落到了你能在终端中复现的现象。
