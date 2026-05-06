# 第四步：观测三节点 Raft 集群与 Autopilot

现在启动一个三节点 Integrated Storage Raft 小集群。脚本会启动三个 Vault 进程，初始化 `raft-1`，让 `raft-2` 与 `raft-3` 加入，再解封所有节点。

```bash
cd /root/operator-lab
./start-raft-cluster.sh
source /root/operator-lab/raft-env.sh
```

先查看 Raft peer 集合：

```bash
vault operator raft list-peers
```

输出中重点观察 `node_id`、`leader` 与 `voter`。在开源版三节点集群中，这三个节点都应是 voter，其中一个是 leader。

查看 HA 成员信息：

```bash
vault operator members
```

查看 Autopilot 视角下的集群状态：

```bash
vault operator raft autopilot state
vault operator raft autopilot get-config
```

可以安全地设置一个保守的稳定期参数，再读回配置：

```bash
vault operator raft autopilot set-config -server-stabilization-time=10s
vault operator raft autopilot get-config
```

保存并检查 Raft snapshot：

```bash
vault operator raft snapshot save raft.snap
vault operator raft snapshot inspect raft.snap
ls -lh raft.snap
```

最后体验一次主动让位：

```bash
vault operator step-down
vault status
vault operator raft list-peers
```

观察要点：`list-peers` 展示 Raft 配置中的节点；`members` 展示 active node 听说过的 HA peers；`autopilot state` 从健康、投票身份和日志进度角度解释集群；`snapshot save` 是 Integrated Storage 场景下最重要的恢复材料之一。