# 实验完成

恭喜你完成本节实验。在本实验中，你已经：

- 在单台 Killercoda 主机上以端口区分启动了 4 个 Vault 节点（API 8200/8210/8220/8230、cluster 8201/8211/8221/8231），通过 `retry_join` 自动组装出一个 3 节点 Raft 集群，并使用 `vault operator raft list-peers` 与 `vault operator raft autopilot state` 验证了 `Failure Tolerance: 1` 与 `Healthy: true` 的初始状态；
- 通过 `vault operator raft autopilot set-config -server-stabilization-time=30s` 把稳定期调高到 30 秒后再加入 node-4，亲眼观察了 node-4 在前 30 秒以 `Voter=false` 的 non-voter 身份待在集群里、稳定期满后才被 Autopilot 自动晋升为 voter 的过渡过程；
- 启用了 Dead Server Cleanup（`-cleanup-dead-servers=true`、`-dead-server-last-contact-threshold=1m`、`-min-quorum=3`）后 kill 掉 node-4，等候至阈值触发后通过 `list-peers` 确认 node-4 已自动从 peer 列表中消失，**完全无需手工执行 `remove-peer`**；
- 在稳定运行的集群上启用了 KV v2 引擎、写入业务数据，并用 `vault operator raft snapshot save /root/raft-good.snap` 拍下离线快照、用 `snapshot inspect` 验证文件结构；
- 同时 kill node-2 与 node-3 复现了 quorum 永久丢失场景，通过在 node-1 的 raft 子目录写入仅含自身的 `peers.json`、重启并解封，把集群从 quorum 失守状态抢救为单节点可服务状态——亲眼看到 `peers.json` 文件在被消化后被 raft 自动删除的现象；
- 最后执行 `vault operator raft snapshot restore /root/raft-good.snap`，把 `secret/app/db` 的 `password` 从 `AFTER-snapshot-MUST-DISAPPEAR` 回滚到 `before-snapshot`，验证了离线快照的"数据回滚"语义。

至此 6.4 节涉及的 Integrated Storage 协议层、Autopilot 自动驾驶仪、`peers.json` 兜底救援与 raft snapshot 离线快照四套机制的全部边界都被亲手打通了。

下一节将延续配置文件深入方向，讲解 Vault 集群高可用模式（HA）的设计哲学及其数据一致性保障。
