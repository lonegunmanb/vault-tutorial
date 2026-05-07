# 第五步：复现 quorum 永久丢失并通过 peers.json 重建集群

[6.4 节 §10](/ch6-integrated-storage) 详细说明了 quorum 永久丢失场景下的恢复路径：将仅剩节点写入一份只列自身的 `peers.json`，重启后由它独自重新选主。本步在 3 节点集群上复现这一场景——同时杀掉 node-2 与 node-3，然后通过 `peers.json` 让 node-1 作为唯一幸存节点重组集群。

## 5.1 同时杀掉 node-2 与 node-3 复现 quorum 永久丢失

3 voter 集群的 quorum = 2，故同时损失 2 个 voter 即丢 quorum：

```bash
NODE2_PID=$(cat /tmp/vault-2.pid)
NODE3_PID=$(cat /tmp/vault-3.pid)

kill -9 "$NODE2_PID" "$NODE3_PID"
sleep 3
```

立即尝试在仅剩的 node-1 上执行任何写请求，预期失败：

```bash
vault kv put secret/app/db username=alice password=should-fail-no-quorum 2>&1 | head -5
```

错误信息中应当出现 raft quorum / leadership 相关字样——这是预期的：node-1 失去了能选出 leader 所需的多数派。

> **本场景对应 [6.4 节 §10.2](/ch6-integrated-storage)**：quorum 已经丢失、完全停服。教程明确指出"部分恢复仍然是可能的"，且**该场景下可能发生数据丢失**——因为多个节点同时失效时 Raft 自身无法判定哪些 entry 已经被 commit。本实验的恢复目标不是追求完美一致性，而是把 node-1 上**已经持久化的状态**抢救出来。

## 5.2 在 node-1 上停掉 Vault 进程

按 [6.4 节 §10.3](/ch6-integrated-storage) 第 1 步："停止所有剩余节点。"

```bash
NODE1_PID=$(cat /tmp/vault-1.pid)
kill "$NODE1_PID"
sleep 3
ps -p "$NODE1_PID" || echo "node-1 进程已退出"
```

## 5.3 在 node-1 的 raft 数据目录中写入 `peers.json`

[6.4 节 §10.3](/ch6-integrated-storage) 第 2-3 步：进入节点的 data path → raft 子目录 → 创建 `peers.json`。本实验中 node-1 的 data path 是 `/opt/vault/data-1`，对应的 raft 子目录是 `/opt/vault/data-1/raft`：

```bash
ls -la /opt/vault/data-1/raft/
```

应能看到 `raft.db`、`snapshots/` 等文件——这是 raft 状态机的物理存储。

按"仅将 node-1 自身列为 peer"的极端情况编写 `peers.json`（参考 [6.4 节 §10.2](/ch6-integrated-storage) 末尾"In extreme cases..."段）：

```bash
cat > /opt/vault/data-1/raft/peers.json <<'EOF'
[
  {
    "id":      "node-1",
    "address": "127.0.0.1:8201",
    "non_voter": false
  }
]
EOF

cat /opt/vault/data-1/raft/peers.json
```

> **关键注意点**（来自 [6.4 节 §10.3](/ch6-integrated-storage) 字段说明）：
>
> - `id` 必须与该节点 `vault.hcl` 中 `node_id = "node-1"` 完全一致；
> - `address` 中的端口是 **cluster port（8201）**，**不是 API port（8200）**——这一点是新手最常犯的错误；
> - `non_voter` 在开源版固定填 `false`。

## 5.4 重启 node-1 触发 peers.json 接管

```bash
./start-node.sh 1
sleep 5

vault status || true
```

启动后 `peers.json` 会被 raft 子系统读取并消化——你能在 `/var/log/vault-1.log` 中看到类似日志：

```bash
grep -i "peers.json\|recovery" /var/log/vault-1.log | head -20
```

会出现诸如 "found peers.json file, recovering Raft configuration..." 之类的字样，并且 `peers.json` 文件在被消化后会被 raft 自动**删除**：

```bash
ls /opt/vault/data-1/raft/peers.json 2>&1
```

预期输出 `No such file or directory`——这是 raft 设计：peers.json 是一次性消耗品，正是 [6.4 节 §10.3](/ch6-integrated-storage) 开头警告"绝对不要把该文件纳入任何'周期性自动重写'的脚本"的根源。

## 5.5 解封 node-1 并验证集群已恢复

```bash
vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)"

echo "等待 node-1 解封完成 ..."
until curl -sS "http://127.0.0.1:8200/v1/sys/seal-status" \
  | jq -e '.sealed == false' >/dev/null; do
  curl -sS "http://127.0.0.1:8200/v1/sys/seal-status" \
    | jq '{initialized,sealed,progress,cluster_id}'
  sleep 2
done

curl -sS "http://127.0.0.1:8200/v1/sys/seal-status" \
  | jq '{initialized,sealed,cluster_id}'
```

`"sealed": false` 表示 node-1 已成功解封。

确认集群成员已收敛到只剩 node-1：

```bash
vault operator raft list-peers
```

预期输出仅一行：

```
Node      Address           State    Voter
----      -------           -----    -----
node-1    127.0.0.1:8201    leader   true
```

验证业务读取依然可用——读取 Step 4 写入的 KV 数据：

```bash
vault kv get secret/app/db
vault kv get secret/app/api
```

注意此时 `secret/app/db` 的 `password` 字段是 **`AFTER-snapshot-MUST-DISAPPEAR`**——也就是 Step 4 末尾"快照之后"的修改。这表明 node-1 上的 raft 状态机在 quorum 丢失之前已经持久化了这条修改，并且重组后被保留下来。

> **学术观察**：这一现象与 [6.4 节 §10.2](/ch6-integrated-storage) 的官方警告"恢复过程会将所有未决（outstanding）raft log entry 隐式 commit"完全一致——本实验中 node-1 在 quorum 失守的瞬间已 apply 了"AFTER-snapshot"那条 log entry，即使该 entry 在原集群中可能尚未达成多数 commit，重组后它也被强制保留下来。

## 5.6 这一步的核心闭环

通过同时 kill node-2 与 node-3 复现了 quorum 永久丢失；按 [6.4 节 §10](/ch6-integrated-storage) 的官方流程在 node-1 的 raft 子目录写入仅含自身的 `peers.json`；重启 + unseal 后单节点集群已恢复到可写入状态，证实"幸存节点 + `peers.json`"路径在零商业授权条件下完全可行。下一步演示如何把数据回滚到 Step 4 拍下的良好状态。
