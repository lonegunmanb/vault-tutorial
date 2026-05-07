# 第六步：用 snapshot restore 把数据回滚至上一已知良好状态

[6.4 节 §12](/ch6-integrated-storage) 把 raft snapshot 的语义定位为"数据回滚"——独立于 Recovery Mode 的另一条恢复维度。本步在已经通过 `peers.json` 重组完毕的单节点集群上，使用 `vault operator raft snapshot restore` 把数据回滚到 Step 4 拍下的快照状态，验证"AFTER-snapshot"那条修改确实被还原。

## 6.1 确认当前数据是"快照之后"的状态

执行恢复前先把现状记录下来，便于对比：

```bash
echo "=== restore 之前 ==="
vault kv get secret/app/db
vault kv get secret/app/api
```

`secret/app/db` 的 `password` 应当是 `AFTER-snapshot-MUST-DISAPPEAR`，对应 Step 4 末尾写入的"快照之后"数据。

## 6.2 执行 snapshot restore

```bash
vault operator raft snapshot restore /root/raft-good.snap
```

> 该命令会立即生效——Vault 会暂停常规写入，把快照内容应用到 raft 状态机上，然后恢复服务。在生产环境中**必须先确认快照来源可信**：snapshot restore 会无条件覆盖当前所有数据，**包括 KV、auth method、policy、token 等全部内容**。

## 6.3 验证数据已回滚至 snapshot 内的状态

```bash
echo "=== restore 之后 ==="
vault kv get secret/app/db
vault kv get secret/app/api
```

预期此时 `secret/app/db` 的 `password` 已经回到 `before-snapshot`——"AFTER-snapshot-MUST-DISAPPEAR" 这条修改被快照覆盖掉，正是我们在 Step 4 标注的对比基准。

为了让对比更清晰，也可以查看 KV v2 的版本元数据：

```bash
vault kv metadata get secret/app/db
```

> **关键观察点**：snapshot restore 后的 `secret/app/db` 的 `current_version` 通常会回到一个较早的版本号（取决于 Step 4 时的版本数）。这表明 `restore` 不是"在现有数据上覆盖一个新版本"，而是**把整个 KV 引擎的全部历史与元数据替换为快照中的状态**——这与 [6.4 节 §12](/ch6-integrated-storage) 中"snapshot restore 用于将 Vault 还原到当时的状态"的描述完全一致。

## 6.4 集群规模仍然为 1：补 join 新节点不在本实验范围

按 [6.4 节 §10.2](/ch6-integrated-storage) 末段的指引，恢复完成后若希望补回原集群规模，新加入的节点必须使用**完全干净**（totally clean）的数据目录，再使用 `vault operator raft join` 加入。本实验**不**演示这一补回过程——因为补 join 需要给 node-2 / node-3 各开一份新的 raft 数据目录、重写 vault.hcl，且 `start-node.sh` 与原 data path 已强绑定。学员可在课后**自行**练习：把 `/opt/vault/data-2` 与 `/opt/vault/data-3` 全部删干净，重启 node-2 / node-3，观察它们是否能通过 `retry_join` 重新加入并被 Autopilot 走完 Server Stabilization 流程。

> **此处真正应当让学员意识到的一点**：snapshot restore 与 `peers.json` 重组是**不同维度**的恢复操作。restore 解决"数据状态"问题，`peers.json` 解决"成员关系"问题。本实验把两者串在一起——先用 `peers.json` 把 quorum 救回来，再用 snapshot restore 把数据拨回到良好状态——是生产环境中 quorum 永久丢失场景下的标准恢复流程。

## 6.5 这一步的核心闭环

执行 `vault operator raft snapshot restore` 把整个 raft 状态机回滚到 Step 4 拍下的快照——`secret/app/db` 中"AFTER-snapshot"那条修改确实消失，回到 `before-snapshot` 状态。至此 quorum 失守 → `peers.json` 重组 → snapshot restore 数据回滚的完整链路全部跑通。
