# 第一步：启动 3 节点 Raft 集群并初始化

[6.4 节正文](/ch6-integrated-storage) §3 与 §4 介绍了 Raft 集群的 join 流程：node-1 作为 bootstrap 节点单独启动并初始化（结果是大小为 1 的集群），node-2 与 node-3 通过 `retry_join` 自动加入。本步把这一流程在本机端口隔离的 4 节点骨架上跑通其中前 3 个节点。

## 1.1 启动 node-1 并初始化

按 bootstrap 节点 → 其它节点的顺序依次启动。先把 node-1 拉起来：

```bash
./start-node.sh 1
sleep 3
vault status || true
```

由于 Vault 尚未初始化，`vault status` 会输出 `Initialized: false` 与一个非零退出码——这是预期的。

对 node-1 执行初始化。本实验使用 Shamir seal（不接 KMS），因此分片由 `vault operator init` 生成：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

cat /root/init-output.json | jq '{unseal_keys: .unseal_keys_b64, root_token: .root_token}'
```

> **本实验为简化起见使用 1/1 分片**（生产环境推荐 5/3 或更高）；这是为了让学员把注意力集中在 Autopilot 行为，而非分片管理本身。

把 unseal key 与 root token 持久化到环境变量便于后续步骤使用：

```bash
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh

vault operator unseal "$UNSEAL_KEY"
```

`vault operator unseal` 应输出 `Sealed: false`，node-1 解封完成。

## 1.2 启动 node-2 与 node-3 让它们通过 `retry_join` 自动加入

node-2 与 node-3 的配置文件中已经写好 `retry_join { leader_api_addr = "http://127.0.0.1:8200" }`。把它们拉起来：

```bash
./start-node.sh 2
./start-node.sh 3
sleep 5
```

由于本实验使用 Shamir seal（而非 auto-unseal），按 [6.4 节 §3](/ch6-integrated-storage) 的说明，`retry_join` 完成后 node-2 与 node-3 仍需要被人工 unseal——它们已经成功 join 了集群，但仍处于 sealed 状态。

分别 unseal node-2 与 node-3（这里直接从 `init-output.json` 重新读取 key，不依赖前一段写入的环境变量——Killercoda 中每个代码块可能在独立 shell 里执行，`/etc/profile.d/vault.sh` 不一定被 source）：

```bash
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
VAULT_ADDR=http://127.0.0.1:8210 vault operator unseal "$UNSEAL_KEY"
VAULT_ADDR=http://127.0.0.1:8220 vault operator unseal "$UNSEAL_KEY"
```

每条命令的输出最末尾应当是 `Sealed: false`。如果看到 `Unseal Progress: 0/1` 与 `Sealed: true`，说明 `$UNSEAL_KEY` 是空的——重新执行上面这段从 `init-output.json` 读取的命令即可。

> 注意 unseal 时通过 `VAULT_ADDR=...` 临时把 CLI 指向目标节点，但本步**没有改动当前 shell 的 `VAULT_ADDR`**——所以默认 8200 仍然指向 node-1。

## 1.3 用 `list-peers` 与 `autopilot state` 验证集群

在默认 `VAULT_ADDR=http://127.0.0.1:8200` 下查看 peer 集合：

```bash
vault operator raft list-peers
```

预期输出形如：

```
Node      Address           State       Voter
----      -------           -----       -----
node-1    127.0.0.1:8201    leader      true
node-2    127.0.0.1:8211    follower    true
node-3    127.0.0.1:8221    follower    true
```

3 个节点全部 `Voter=true`，node-1 是 leader——一个标准的 3 voter 集群。

接着查看 Autopilot 视角下的整体状态：

```bash
vault operator raft autopilot state
```

输出应当显示 `Healthy: true` 与 `Failure Tolerance: 1`——3 voter 集群最多可以损失 1 个 voter 而仍维持 quorum，与 [6.4 节 §8](/ch6-integrated-storage) 中"Deployment Table"对应。

最后查看 Autopilot 的当前配置（确认默认值与文档一致）：

```bash
vault operator raft autopilot get-config
```

预期所有阈值为默认值：`Cleanup Dead Servers = false`、`Last Contact Threshold = 10s`、`Dead Server Last Contact Threshold = 24h0m0s`、`Server Stabilization Time = 10s`、`Min Quorum = 0`、`Max Trailing Logs = 1000`、`Disable Upgrade Migration = false`。

## 1.4 这一步的核心闭环

3 节点 Raft 集群通过 `retry_join` 自动组装完成；leader 已选出，failure tolerance = 1；Autopilot 正在以默认参数运行。下一步开始观察 Server Stabilization Time 在新节点加入时的真实行为。
