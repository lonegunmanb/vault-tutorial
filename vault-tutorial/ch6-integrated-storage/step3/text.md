# 第三步：启用 Dead Server Cleanup 让 Autopilot 自动剔除被 kill 的节点

[6.4 节 §7](/ch6-integrated-storage) 已说明：Dead Server Cleanup 默认关闭，启用时必须同时设置 `cleanup_dead_servers=true` 与 `min_quorum`，并通过 `dead_server_last_contact_threshold` 控制触发清理的阈值。本步把这一闭环跑通——杀掉 node-4，等候 Autopilot 自动把它从 peer 列表中清除。

## 3.1 启用 Dead Server Cleanup 并把阈值调小至 1 分钟

按 [6.4 节 §7](/ch6-integrated-storage) 引用的官方教程示例（**仅供演示，不可在生产环境使用**）：

```bash
vault operator raft autopilot set-config \
  -dead-server-last-contact-threshold=1m \
  -server-stabilization-time=30s \
  -cleanup-dead-servers=true \
  -min-quorum=3
```

关键参数解读：

- `-cleanup-dead-servers=true`：启用自动清理；
- `-dead-server-last-contact-threshold=1m`：节点失联超过 1 分钟即被判定为"已失败"——**生产环境务必保持 24 小时这种较高量级**，本实验仅为加速演示而调小；
- `-min-quorum=3`：Autopilot 不会把节点数 prune 到 3 以下；这意味着当前 4 voter 集群中最多允许 Autopilot 自动剔除 1 台。

立即验证更改：

```bash
vault operator raft autopilot get-config
```

预期 `Cleanup Dead Servers` 为 `true`，`Dead Server Last Contact Threshold` 为 `1m0s`，`Min Quorum` 为 `3`。

## 3.2 杀掉 node-4 模拟硬件故障

```bash
NODE4_PID=$(cat /tmp/vault-4.pid)
kill -9 "$NODE4_PID"
sleep 2
ps -p "$NODE4_PID" || echo "node-4 进程已退出"
```

立即查看 peer 列表：

```bash
vault operator raft list-peers
```

此时 node-4 仍然出现在 peer 列表中（因为它刚刚才失联，还未达到 1 分钟阈值）：

```
node-4    127.0.0.1:8231    follower    true
```

`autopilot state` 中 node-4 的 `Healthy` 字段会立即变为 `false`，但 `Status` 仍然是 `voter`（清理动作尚未触发）：

```bash
vault operator raft autopilot state
```

## 3.3 等待阈值触发后观察 Autopilot 自动清理

等待至少 90 秒（阈值 1 分钟 + Autopilot 默认 10 秒轮询间隔的若干周期，预留充分余量）：

```bash
echo "等待 Dead Server Cleanup 触发（约 90 秒）..."
for i in $(seq 1 9); do
  sleep 10
  echo "[已等待 $((i*10)) 秒] 当前 peer 数： $(vault operator raft list-peers 2>/dev/null | tail -n +3 | wc -l)"
done
```

清理触发后再查看 peer 列表：

```bash
vault operator raft list-peers
```

预期 node-4 已经从 peer 列表中消失，输出仅剩 node-1/2/3：

```
Node      Address           State       Voter
----      -------           -----       -----
node-1    127.0.0.1:8201    leader      true
node-2    127.0.0.1:8211    follower    true
node-3    127.0.0.1:8221    follower    true
```

`autopilot state` 此时 `Healthy: true`、`Failure Tolerance: 1`，集群恢复到完全健康的 3 voter 状态：

```bash
vault operator raft autopilot state | head -5
```

## 3.4 思考：为什么 `min_quorum=3` 会成为护栏

倘若再杀掉一个节点，`min_quorum=3` 会阻止 Autopilot 进一步清理——即使该节点超过失联阈值，Autopilot 也会拒绝 prune，因为 prune 后集群将跌破 `min_quorum`。这一护栏防止 Autopilot 把集群直接清到 quorum 失守的危险状态。

> 学员可在课后**自行**验证这一点：再次启动 node-4 + unseal + 等待稳定期，使其重新晋升为 voter；然后同时 kill node-3 与 node-4。观察 Autopilot 在 1 分钟阈值过后是否会真的把它们从 peer 列表中移除——按 `min_quorum=3` 的语义，至少应该有一个节点保留下来。

## 3.5 这一步的核心闭环

启用了 Dead Server Cleanup 并把阈值缩短到 1 分钟，亲眼观察了 Autopilot 在节点失联超过阈值后自动把它从 peer 列表中清除——完全无需人工执行 `remove-peer`。下一步开始为 quorum 永久丢失场景的演示做准备：先写入业务 KV 数据并保存一份 raft snapshot。
