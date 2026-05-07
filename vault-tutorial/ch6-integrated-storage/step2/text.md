# 第二步：调高 Server Stabilization Time 后加入 node-4 观察 non-voter 期

[6.4 节 §6](/ch6-integrated-storage) 已经讲清楚 Server Stabilization Time 的作用：新 voter 节点 join 时被 Autopilot 临时降级为 non-voter，并必须保持 healthy 至少这段时间长度才会被晋升为 voter。本步把这段时间从默认 10 秒调高到 30 秒，再加入 node-4，亲眼观察 `Voter=false → Voter=true` 的过渡过程。

## 2.1 把 Server Stabilization Time 调高至 30 秒

执行 `set-config` 命令：

```bash
vault operator raft autopilot set-config \
  -server-stabilization-time=30s
```

> 注意此处 `-server-stabilization-time` 接受的是 Go 的 duration 字符串（如 `30s`、`1m`、`5m`）。官方教程示例 [来源：TUT-AUTOPILOT § Autopilot configuration] 中写法为 `-server-stabilization-time=30`，CLI 会按秒解析；本实验为更明确而显式带 `s` 后缀。

立即验证更改已生效：

```bash
vault operator raft autopilot get-config | grep "Server Stabilization Time"
```

预期输出 `Server Stabilization Time             30s`。

## 2.2 启动 node-4 并立即 unseal

```bash
./start-node.sh 4
sleep 3
VAULT_ADDR=http://127.0.0.1:8230 vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)"

echo "等待 node-4 完成 retry_join + unseal ..."
until curl -sS "http://127.0.0.1:8230/v1/sys/seal-status" \
  | jq -e '.sealed == false' >/dev/null; do
  curl -sS "http://127.0.0.1:8230/v1/sys/seal-status" \
    | jq '{initialized,sealed,progress,cluster_id}'
  sleep 2
done

curl -sS "http://127.0.0.1:8230/v1/sys/seal-status" \
  | jq '{initialized,sealed,cluster_id}'
```

最终输出应当显示 `"sealed": false`，node-4 已加入集群并解封。

## 2.3 立即查看 peer 列表，确认 node-4 是 non-voter

```bash
vault operator raft list-peers
```

此时应能在输出最后看到一行类似：

```
node-4    127.0.0.1:8231    follower    false
```

`Voter` 字段为 `false`——这正是 [6.4 节 §6](/ch6-integrated-storage) 引用的官方教程现象："The vault_7 server joins the cluster as a non-voter until the Server Stabilization Time of 30 seconds elapses."

也可以用 `autopilot state` 查看更详细信息：

```bash
vault operator raft autopilot state
```

输出中 `Servers` 段内对应 node-4 的部分会显示 `Status: non-voter` 与 `Healthy: true`。

## 2.4 等待稳定期结束并再次确认晋升为 voter

在主机上等待至少 35 秒（稍微超过配置的 30 秒以容许 Autopilot 的轮询间隔）：

```bash
echo "等待稳定期结束（约 35 秒）..."
sleep 35

vault operator raft list-peers
```

预期此时 node-4 行的 `Voter` 字段已变为 `true`：

```
node-4    127.0.0.1:8231    follower    true
```

至此 4 个节点全部为 voter；但 `Failure Tolerance` 仍然是 1（4 voter 集群与 3 voter 集群的 failure tolerance 相同，均为 1）：

```bash
vault operator raft autopilot state | head -5
```

> **学术提示**：4 voter 与 3 voter 的 failure tolerance 相同（均为 1），是因为 Raft 协议要求 `(N/2)+1` 票才能 commit；3 voter 时 quorum=2、可损失 1，4 voter 时 quorum=3、可损失 1。**为偶数 voter 部署集群在容错维度上没有任何收益**——这是 [6.4 节 §8](/ch6-integrated-storage) 中"Deployment Table"反复强调的事实。本实验为了演示 non-voter 期才临时把集群扩到 4 voter；下一步会让 node-4 主动失效，从而把集群拉回到 3 voter 标准状态。

## 2.5 这一步的核心闭环

通过 `set-config` 把 Server Stabilization Time 调高至 30 秒，亲眼观察了新加入的 node-4 在前 30 秒以 non-voter 身份待在集群里、稳定期满后才被 Autopilot 晋升为 voter。下一步演示 Dead Server Cleanup：把 node-4 杀掉后让 Autopilot 自动把它从 peer 列表中清除。
