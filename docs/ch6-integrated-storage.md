---
order: 64
title: 6.4 现代存储引擎的绝对基石：Integrated Storage (Raft) 协议与自动化运维
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.4 现代存储引擎的绝对基石：Integrated Storage (Raft) 协议与自动化运维

> **核心结论**：Integrated Storage 是 Vault 自带的、基于 Raft 一致性协议的高可用持久化存储后端，无需依赖任何第三方系统即可在多节点之间同步数据。Vault 1.7 引入的 Autopilot 子系统会自动接管"新节点稳定期观察"与"死节点清理"等原本必须手工执行的高风险运维流程；Recovery Mode 则是当 Vault 进程因数据损坏或 bug 而完全无法启动时的最后兜底通道。本节按"协议与数据模型 → 自动驾驶仪 → 兜底救援与离线快照"的顺序对这三套机制的边界进行系统性说明。

本节是第 6 章配置文件深入系列的第四节，承接 6.1（顶层块结构）/ 6.2（listener 与 TLS）/ 6.3（auto-unseal）三节，目标是把 Vault 在 Integrated Storage 这条独立技术线上学员**必须掌握**的概念与命令一次性铺平：Raft 协议在 Vault 中的物化形态、`storage "raft"` 块的关键配置项、Autopilot 在新节点加入与故障节点退出两条路径上的行为、Recovery Mode 的启动方式与受限 API 子集，以及在 quorum 永久丢失时如何借助 `peers.json` 与 `operator raft snapshot` 抢救集群。

> 本节不再重复讲解 Raft 集群的从零搭建步骤——这部分基础在第 6.1 节"`storage` 是必填顶层块"以及官方"Vault HA Cluster with Integrated Storage"教程中已经覆盖；本节假定学员已经能够使用一份 `vault.hcl` 启动一个单节点 Raft Vault，重点解释"集群拓扑变化时究竟发生了什么"以及"出现严重故障时如何恢复"。

---

## 1. Integrated Storage 在 Vault 中的位置

Integrated Storage 是 Vault 自 1.4 版本起正式提供（GA）的内置存储选项；它不依赖任何第三方系统，自身实现高可用语义，并支持企业版的复制特性以及备份 / 恢复工作流。

它的工作方式是把 Vault 的全部数据写入每台 Vault 服务器自身的本地文件系统，并使用 Raft 一致性协议（consensus protocol）把变更复制到集群中的每一台服务器。

Vault 1.2 首次以技术预览（technical preview）形式引入了内置存储后端，到 Vault 1.4 正式 GA。在 Integrated Storage 上，数据通过 Raft 一致性协议被复制到集群的每一台节点；在 Autopilot 出现之前，集群节点的管理是一项手工流程。

> 关于"为什么 Vault 总要选择一个存储后端、Vault 自身存储抽象与底层 KMS 加密的关系"等更前置的概念，第 6.1 节已经介绍；本节的重点限于"选择 raft 之后"才会出现的话题。

![Integrated Storage 在 Vault 中的位置：每个 Vault 节点本地落盘，并由 Raft 复制层组成的分布式存储后端](/images/ch6-integrated-storage/integrated-storage-position.png)

---

## 2. `storage "raft"` 块与节点之间的网络通信

Integrated Storage 要求每个 Vault 节点都正确设置 [`cluster_addr`](https://developer.hashicorp.com/vault/docs/concepts/ha#per-node-cluster-address) 这一顶层配置项；该字段在节点 join 集群时把"node ID"与"对外可达地址"绑定起来。

节点彼此 join 完成后，它们会通过 Vault 的 **cluster port** 使用 mTLS 互相通信。该端口默认是 `8201`，所用 TLS 证书与密钥在 join 阶段交换，并按一定周期自动轮换。

> 此处所述的"自动轮换"特指 Vault 节点之间用于集群内部 RPC 的 TLS 凭据，与 6.2 节中讨论的 listener 对外 TLS 证书完全是两套独立体系：listener 证书面向客户端 API 流量、由运维人员维护；cluster port 的证书由 Vault 自身生成并维护，运维人员通常无需直接介入。

集群成员关系（cluster membership）是在 Vault 完成 [初始化](https://developer.hashicorp.com/vault/tutorials/getting-started/getting-started-deploy#initializing-the-vault) 阶段被引导（bootstrap）出来的，初始结果为大小为 1 的集群；之后再依据官方"Deployment Table"中给出的目标集群规模，把其它节点 join 到当前的活跃节点（active node）上。

---

## 3. 节点加入（Join）的两条路径与 join 期间的特殊网络流向

将一个未初始化（uninitialized）的 Vault 节点变为已有集群的成员，这一动作称为 join。

新节点必须使用与目标集群**相同的 seal 机制**才能完成 join：若集群使用 auto-unseal，则新节点必须配置为使用同一个 KMS 提供商与同一把 key；若集群使用 Shamir seal，则必须先把 unseal keys 提供给新节点，否则 join 流程无法完成。一旦节点成功 join，活跃节点上的数据将开始复制到该节点；并且——**已经 join 过的节点不能被重新 join 到其它集群上**。

新节点 join 时必须使用集群活跃节点的 **API 地址**（而非 cluster port），并且官方建议把每个节点的顶层 [`api_addr`](https://developer.hashicorp.com/vault/docs/concepts/ha#direct-access) 都显式配置好，以简化 join 流程。**应当一次只 join 一个节点**，并等其变为健康状态（必要时还要等其晋升为 voter）后再继续添加下一个；可以使用 [`list-peers`](https://developer.hashicorp.com/vault/docs/commands/operator/raft#list-peers) 或 [`autopilot state`](https://developer.hashicorp.com/vault/docs/commands/operator/raft#autopilot-state) 检查节点状态。

join 既可以通过配置文件中的 `retry_join` 节自动完成，也可以通过 `vault operator raft join <leader_api_addr>` 命令手动完成。在使用 `retry_join` 时，未初始化的 Vault 节点启动后会按配置不断尝试连接每一个候选 leader 直至成功；若集群使用 Shamir seal，则 join 完成后该新节点仍需要被人工 unseal；若集群使用 auto-unseal，则新节点能够在 join 完成后自动 unseal。

为何 join 阶段必须经过 API port 而不是直接使用 cluster port？此处存在一个先有鸡还是先有蛋的问题：**集群只有在 raft 形成之后才共享存储视图**，而 join 这一动作恰恰发生在"raft 尚未形成"的时刻——新节点尚无法访问现有集群中持久化保存的那张 cluster TLS 证书。Vault 解决这一问题的方式是：让新节点和现有节点先通过 API port 完成一次"挑战 / 应答"流程；只有当新节点能够使用自身的 seal 解开现有节点发出的 challenge UUID 时，现有节点才确认其可信，进而通过一个 bootstrap package 把 cluster TLS 证书与私钥传递给它，自此之后所有节点间通信均切换为 cluster port。这是 Vault 社区版中**目前唯一一处**节点之间通过 API port 通信的场景。

![Vault Raft join 阶段的特殊握手：先在 API port 进行 challenge/response，握手成功后再切换到 cluster port 进行 mTLS 通信](/images/ch6-integrated-storage/raft-join-handshake.png)

---

## 4. 列出与移除节点：`list-peers` 与 `remove-peer`

要查看集群当前的 peer 集合，可以执行 `vault operator raft list-peers`，输出会列出每个节点的 ID、地址、状态与 voter 标志位。**全部 voter 节点共同构成 quorum，并且在任何时刻必须有过半数的 voter 节点存活，Integrated Storage 才能继续工作**。

```text
$ vault operator raft list-peers
Node     Address                   State       Voter
----     -------                   -----       -----
node1    node1.vault.local:8201    follower    true
node2    node2.vault.local:8201    follower    true
node3    node3.vault.local:8201    leader      true
```



当某个节点确认不再回到集群（例如硬件下线、主机名永久变更、缩容），可以使用 `vault operator raft remove-peer <node_id>` 将其从 peer 集合中移除，从而保证集群规模与 quorum 不被空挂的失效节点拖累。

被 `remove-peer` 移除过的节点若以后希望重新加入集群，必须先**停止该节点的 Vault 进程、删除其 raft 数据目录、然后再重启**，最后才能再次执行 join；否则它携带旧的 raft 状态返回会引发冲突。

---

## 5. Autopilot 三大开源能力：稳定期、死节点清理、State API

至此我们已经讲清楚"手工运维一个 Raft 集群"需要做的事情：将节点 join 进来、使用 `list-peers` 监控、使用 `remove-peer` 清理失效节点。Autopilot 的目标即是把后两件事尽可能自动化。

Autopilot 是一个为 Raft 集群提供自动化工作流的子系统。开源版（Community Edition）能够使用的功能有 3 项：**Server Stabilization**（服务器稳定期）、**Dead Server Cleanup**（死节点清理）和 **State API**（状态接口）；这 3 项均在 Vault 1.7 引入。Vault 企业版还在此之上额外提供 Automated Upgrades（自动版本迁移）与 Redundancy Zones（冗余区），这两项是 1.11 引入。

> **课程边界声明**：本节仅讲解开源版可用的 3 项，并明确将 Automated Upgrades 与 Redundancy Zones 标注为"企业版功能、不在本课程动手范围"。后文遇到这两个名词时，仅作概念介绍以避免学员在阅读官方文档时产生困惑。

Autopilot 在升级到 Vault 1.7+ 的集群中**默认启用**——但是，Server Stabilization 默认即生效，而 Dead Server Cleanup 必须显式启用。

---

## 6. 服务器观察稳定期（Server Stabilization Time）

Server Stabilization 的作用是在新 voter 节点加入既有集群时保护 Raft 集群的稳定性。当一个新 voter 节点 join 进来时，Autopilot 会**先以 non-voter 身份将其加入**，然后等待一段预设的时间观察其健康状况；若该节点在整个稳定期内一直保持健康，Autopilot 才会将其晋升（promote）为 voter。这段稳定期可以通过 `server_stabilization_time` 调节。

> **为何不能让新节点直接担任 voter**？Raft 协议层本身允许新节点立即拥有投票权，但在工程层面，新节点的 raft log 通常远落后于 leader：刚 join 完成时它需要先把 leader 的快照与 log 同步过来并重放。若在这段"尚未追上"的时间窗内 leader 突然崩溃需要重新选举，落后的新节点反而可能赢得选举，从而把状态机倒退至旧版本。Autopilot 的稳定期就是从工程层面消除这一危险窗口：在稳定期结束前，新节点仅作为观察者存在，不参与投票，落后多远也不会影响 quorum。

`server_stabilization_time` 的默认值是 `"10s"`，含义为：**在被允许成为 voter 之前，节点必须保持 healthy 状态的最短时间**。在那之前节点会以 peer 身份出现在集群中，但作为 non-voter，不计入 quorum。

下面这段官方教程实操片段非常具象地演示了这一机制。教程中先把 Server Stabilization Time 调高至 30 秒（默认是 10 秒）再加入新节点 vault_7：

```text
$ vault operator raft list-peers

Node       Address           State       Voter
----       -------           -----       -----
vault_2    127.0.0.1:8201    leader      true
vault_3    127.0.0.1:8301    follower    true
vault_4    127.0.0.1:8401    follower    true
vault_5    127.0.0.1:8501    follower    true
vault_7    127.0.0.1:8701    follower    false
```

新节点 vault_7 在 join 后立即列出时 Voter 字段为 `false`；待配置的稳定期结束之后再次执行 list，vault_7 的 Voter 字段即变为 `true`。

> 教程原文："The vault_7 server joins the cluster as a non-voter until the Server Stabilization Time of 30 seconds elapses." 与 "Now, the vault_7 server should be a voter. This is a part of the server stabilization mechanism of the autopilot."

![新节点加入时 Autopilot 先将其放入 non-voter 区，稳定期结束后再晋升为 voter 的过程](/images/ch6-integrated-storage/server-stabilization-flow.png)

---

## 7. 死节点无痛自动清理（Dead Server Cleanup）

Dead Server Cleanup 的作用是从 Raft cluster 中**自动移除**被判定为不健康的节点，从而避免运维人员手工执行 `remove-peer`。该特性可以通过 `cleanup_dead_servers`、`dead_server_last_contact_threshold` 与 `min_quorum` 三个参数调节。

Autopilot 视角下 follower 节点的健康判定有两个维度：

1. 是否能够按规则的间隔向 leader 发送心跳（heartbeat）。该维度由 `last_contact_threshold` 调节。
2. 是否能够跟上从 leader 复制下来的数据。该维度由 `max_trailing_logs` 调节。



Autopilot 的所有这些参数**只能通过 API（或 CLI 包装层）配置，不能写入 Vault 服务器配置文件**。Autopilot 启动时会按下列默认值初始化；若默认值不符合期望，需要主动修改。

| 参数 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `cleanup_dead_servers` | `false` | 是否定期或在新节点 join 时自动从 Raft peer 列表中移除失效节点。启用此项**必须同时设置 `min_quorum`**。 |
| `dead_server_last_contact_threshold` | `"24h"` | 一台 server 多久未与 leader 通信即被判定为"已失败"。仅在 `cleanup_dead_servers` 启用后才生效。新节点加入时，该阈值需要大于"加载 raft 快照所需时间"，否则刚 join 的新节点会因为仍在加载快照而被误删；若使用了 HSM，该阈值也必须大于 HSM 的响应时间。**官方强烈建议保持在一天这种较高量级，过低会导致节点被误删。** |
| `min_quorum` | 无默认值 | 集群中始终应保留的最小 server 数；Autopilot 不会将节点数 prune 至此值以下。`cleanup_dead_servers=true` 时，应将其设为集群预期的 voter 数。 |
| `max_trailing_logs` | `1000` | 一台 server 最多可以落后 leader 多少条 raft 日志而仍被视为健康。值过低会导致 follower 略有滞后即被认定为不健康。绝大多数用户无需修改该值。 |
| `last_contact_threshold` | `"10s"` | 一台 server 多久未与 leader 通信即被判定为"不健康"（注意与 `dead_server_last_contact_threshold` 的"已失败"加以区分）。 |
| `server_stabilization_time` | `"10s"` | 见上一节。 |
| `disable_upgrade_migration` | `false` | 关闭 Autopilot 自动升级——**仅企业版可用**。 |

> **"不健康"与"已失败"两个阈值之间的区别非常关键**：`last_contact_threshold`（默认 10 秒）只是把节点状态标记为不健康，但不会对其执行任何动作；`dead_server_last_contact_threshold`（默认 24 小时）才是触发自动清理的门槛。这种"两级阈值"的设计意图是为短暂网络抖动留出充分缓冲，避免一次轻微波动即导致节点从集群中被剔除。

调大或调小这些参数的命令是 `vault operator raft autopilot set-config`。下面这段官方教程的调用即是把 `dead_server_last_contact_threshold` 缩短至 1 分钟（仅供演示，**严禁在生产环境使用**）、把稳定期调至 30 秒、并显式将 `min_quorum` 设为 3：

```text
$ vault operator raft autopilot set-config \
    -dead-server-last-contact-threshold=1m \
    -server-stabilization-time=30 \
    -cleanup-dead-servers=true \
    -min-quorum=3
```



更改后使用 `get-config` 验证：

```text
$ vault operator raft autopilot get-config
Key                                   Value
---                                   -----
Cleanup Dead Servers                  true
Last Contact Threshold                10s
Dead Server Last Contact Threshold    1m0s
Server Stabilization Time             30s
Min Quorum                            3
Max Trailing Logs                     1000
Disable Upgrade Migration             false
```



清理触发后再次执行 `list-peers`，被清理的失效节点（教程中的 vault_6）即不再出现在 peer 列表中：

```text
$ vault operator raft list-peers
Node       Address           State       Voter
----       -------           -----       -----
vault_2    127.0.0.1:8201    leader      true
vault_3    127.0.0.1:8301    follower    true
vault_4    127.0.0.1:8401    follower    true
vault_5    127.0.0.1:8501    follower    true
```



> 关于 Vault Autopilot 与 Consul autopilot 之间的关系：Vault 中的 Autopilot 在概念上与 Consul 中的 autopilot 类似，但**默认值与阈值不同，部分参数也仅在 Vault 中存在**——这是因为两者底层实现不同。所以在对照阅读 Consul 文档时不应直接套用其参数取值。

---

## 8. State API：通过单次调用获取集群整体视图

State API 提供"在一次调用中查看 Raft cluster 全部节点的详细信息"，可用于实施集群健康监控。

CLI 上对应的命令是 `vault operator raft autopilot state`。一份典型的输出如下（节选）：

```text
$ vault operator raft autopilot state

Healthy:                      true
Failure Tolerance:            2
Leader:                       vault_2
Voters:
   vault_2
   vault_3
   vault_4
   vault_5
   vault_6
Servers:
   vault_2
      Name:            vault_2
      Address:         127.0.0.1:8201
      Status:          leader
      Node Status:     alive
      Healthy:         true
      Last Contact:    0s
      Last Term:       3
      Last Index:      118
   ...
```



输出中有两个数字最需要关注：

- **Failure Tolerance** = 集群当前还能损失多少 voter 而 quorum 不丢失。该字段直接反映"再损失一个节点会发生什么"。在 5 voter 的集群中，Failure Tolerance 为 2 意味着可以再损失 2 个节点仍能正常服务；当某个节点状态变为不健康时，该数值会立即下降。
- **Healthy** = 集群整体是否健康。这是一个 `true`/`false` 字段；只要任何一个 voter 节点变为 unhealthy，集群整体的 Healthy 即由 `true` 变为 `false`。

不同集群规模下的 quorum 大小与失败容忍数，请参考官方"Deployment Table" [Quorum size and failure tolerance](https://developer.hashicorp.com/vault/docs/internals/integrated-storage#quorum-size-and-failure-tolerance)。

---

## 9. 调整 Autopilot 的状态轮询间隔

Autopilot 默认每 10 秒拾取一次集群状态变化。若需要修改，把 `autopilot_reconcile_interval` 写入 server 配置文件的 `storage` 块即可，例如：

```hcl
storage "raft" {
  path = "/path/to/raft/data"
  node_id = "raft_node_1"

  # overwrite the default interval
  autopilot_reconcile_interval = "15s"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

cluster_addr = "http://127.0.0.1:8201"
```



> 这是**唯一一个写在配置文件中的 Autopilot 相关参数**——其余所有阈值都必须通过 `set-config` API 调整。

---

## 10. Outage Recovery：quorum 仍在与 quorum 已失两条路径

至此我们假设 Autopilot 能够处理一切。然而，一旦同时失效的节点数超过 Failure Tolerance，集群就会失去 quorum、无法选主、也无法处理任何写请求。此种情况需要分两条恢复路径处理。

### 10.1 单台或少数节点失效但 quorum 仍在

只要剩余节点仍能选出 leader、仍能处理写请求，则 quorum 仍然存在。

若失效节点本身可恢复（机器仍能启动、磁盘仍然完好），最佳选择是**使用相同的 host address 重新启动**该节点，使其自行回到集群。

若不可恢复，则使用 `remove-peer` 命令将该失效节点从集群中移除。

若连 `remove-peer` 都无法执行——例如所有 leader 节点均不可达——则需进一步退化，直接到节点的 raft 数据目录中手工写入一份 `peers.json`（详见下一节）。

### 10.2 quorum 已经丢失：完全停服时的部分恢复

若同时失去多台节点导致 quorum 丢失与完全停服，**部分恢复仍然是可能的**。

若失效节点可恢复，最佳选择是使用相同的 host address 将它们重新启动。

若不可恢复，则基于剩余节点上的数据进行部分恢复。**该场景下可能发生数据丢失**——因为多个节点同时失效时 Raft 自身无法判定哪些 entry 已经被 commit；恢复过程会将所有未决（outstanding）raft log entry 隐式 commit，所以也可能反向 commit 那些原本未 commit 的数据。

恢复的具体动作即是写入 `peers.json`：将**仅剩**的健康服务器列入 `peers.json`，然后将这些服务器都使用同一份 `peers.json` 重启。

之后若希望补回原集群规模，新加入的节点必须使用**完全干净**（totally clean）的数据目录，再使用 `vault operator raft join` 加入。

> **极端情况**：理论上可以仅依靠一台幸存节点完成恢复——把这台节点使用一份"仅将其自身列为 peer 的 `peers.json`"重启即可。该路径**保证可用但极易导致数据丢失**，仅作为最后底线使用。

### 10.3 使用 `peers.json` 手工修复集群成员关系

`raft/peers.json` 是 Raft 这一层的"成员关系兜底文件"。**它会导致未提交的 raft log 被隐式提交**，因此只能在确实没有其它办法可以恢复一台失效节点时才使用，并且**绝对不要把该文件纳入任何"周期性自动重写"的脚本**。

操作步骤如下：

1. 停止所有剩余节点。
2. 进入每台 Vault 节点的 [data path](https://developer.hashicorp.com/vault/docs/configuration/storage/raft/#path)，找到其下的 `raft/` 子目录，在该子目录中创建 `peers.json` 文件。该文件是一个 JSON 数组，每一项包含节点 ID、`address:port` 与 suffrage 信息。
3. 文件示例：

   ```json
   [
     {
       "id":      "node1",
       "address": "node1.vault.local:8201",
       "non_voter": false
     },
     {
       "id":      "node2",
       "address": "node2.vault.local:8201",
       "non_voter": false
     },
     {
       "id":      "node3",
       "address": "node3.vault.local:8201",
       "non_voter": false
     }
   ]
   ```

   字段说明：`id` 是 server 的 node ID（来自配置文件，或来自 server data 目录中那个自动生成的 `node-id` 文件）；`address` 是该 server 的 host:port，注意**此处的端口是 cluster port，而非 API port**；`non_voter` 标志位**是企业版专属的功能**，开源版填 false 即可。
4. 将这份相同的 `peers.json` 写入所有剩余节点，并**确认未列入文件的那些节点确实已经永久失效、不会再返回**。然后将所有节点重启，集群应当回到可操作状态，其中一个节点会赢得选举成为 active 节点。

![Quorum 永久丢失时的恢复路径：将仅剩节点写入同一份 peers.json，重启后由它们重新选主](/images/ch6-integrated-storage/peers-json-recovery.png)

> **关于其它恢复方式**：上述路径仅覆盖"quorum 相关"的故障；若故障与 quorum 无关（典型情况是数据目录损坏导致 Vault 进程根本无法启动），则需走下一节的 Recovery Mode。

---

## 11. Recovery Mode 启动机制与 `-recovery` 标记

Vault 可以使用 `-recovery` 标志启动，进入所谓的 **Recovery Mode**。其主要用途是在 Vault 因为某个新发现的 bug 而**根本无法正常启动**时，提供一条能够直接接触底层存储的通道。**该路径基本不可能在没有 Vault 专家在线指导的情况下被用得正确**——官方文档原话即如此，本节也直接照搬该边界声明给学员。

Recovery Mode 与正常 Vault 运行存在三处差别：

- **常规子系统不再运行**——例如 expiration（租约过期）、clustering、节点之间的 RPC 调用全部停止；
- **不能使用常规的 unseal 流程解封节点**——必须改为生成一个 recovery token；
- **所有请求都打到 `sys/raw`**——并使用 recovery token 而非 service / batch token 鉴权。



> 上述三条边界是 Recovery Mode 与"普通 Vault 进程"之间最直观的差异。可以将其类比为：正常运行模式相当于一辆装配完整的车辆，而 Recovery Mode 则相当于将车辆从外壳下方暴露出来直接操作底盘——可以运转，但操作面非常受限，且仅适用于排障场景。

下面给出 Recovery Mode 的"标准使用流程"，原文是面向所有存储后端通用的版本：

1. seal 或 stop 集群中所有节点；
2. 若使用 Integrated Storage，对每个节点执行一次 `vault status` 找出 raft `AppliedIndex` 最高的那个节点（**该步骤需要节点保持启动且 sealed**——若让其 unsealed，则可能会选出新 leader 并发生写入，导致"哪个节点最新"这一判断被混淆）；
3. 将该目标节点使用 `-recovery` 重启进入 Recovery Mode；
4. 在该节点上生成一个 recovery token；
5. 使用 recovery token 通过 `sys/raw` 修复节点；
6. 若使用 Integrated Storage，按上一节的方式重新组装 raft 集群。



### 11.1 为什么必须选择 AppliedIndex 最高的节点

Integrated Storage 下并非每个节点都"等价"。某些节点可能落后于其它节点——也就是它们 apply 的 raft log 条目数较少。**用作恢复的节点必须选择 AppliedIndex 最高的那个**——否则将基于一份不完整的状态进行修复，这相当于在已经混乱的局面之上叠加一次额外的数据丢失。

每个节点的 AppliedIndex 可以通过对 sealed 状态下的节点执行 `vault status` 获取。

### 11.2 Recovery Token 的特殊语义

Recovery token 的生成方式与 root token 类似，仅是端点不同；并且在生成 recovery token 之前 Vault 节点**必须先处于 sealed 状态**。与 root token 不同的是，recovery token **不会被持久化**——所以一旦把 Vault 重启回 recovery mode，必须重新生成一个；并且**同一时间只能存在一个 recovery token**，丢失后只能重启 Vault 重新生成。

### 11.3 Recovery Mode 下唯一可用的请求路径：`sys/raw`

Recovery Mode 下，请求依然走 `sys/raw` 这一 endpoint，写法与正常 Vault 模式下基本一致——**唯一的区别是 `X-Vault-Token` 头中应放入 recovery token，而非 service / batch token**。

> 关于 `sys/raw`：这是 Vault 暴露的"直接读写底层存储 key/value"的端点，绕过了所有 secret engine 与 policy 层。在生产环境的正常 Vault 中，`sys/raw` 默认是禁用的；Recovery Mode 强制启用它，因此可以将其理解为"将存储这一层临时暴露出来以便实施修复"。

### 11.4 Recovery Mode 会自动将集群缩减为 1 节点

Recovery Mode 下的 Vault 会**自动将集群尺寸缩减为 1**。这是必要的：Raft 协议在 quorum 不达成时不允许变更，而 Recovery Mode 的目标即是"使用单节点直接修改"，所以协议层面必须仅剩 1 个节点。

这意味着，Recovery Mode 使用完毕后**回归正常服务**的流程必须包含"重新组装 raft 集群"。重组方式有两种：

- 删除其它节点的 vault data 目录，再将其重新 join 至刚才那台已恢复的节点；
- 或者，使用上一节的 [Manual Recovery Using peers.json](#_10-3-使用-peers-json-手工修复集群成员关系) 让所有节点对成员关系达成一致。



### 11.5 hybrid `ha_storage` 模式的特别注意

若 Integrated Storage 是以 hybrid 模式作为 `ha_storage` 使用（即 raft 仅承担高可用而不承担数据持久化），则 Recovery Mode 不能用于修改 raft 数据，而是修改下层物理 storage backend 上对应的数据；本节关于 Integrated Storage 的所有说明在该 hybrid 模式下不适用。

> 本课程的讲解和实验全部基于"`storage "raft"`，且 raft 同时承担数据存储与 HA 协调"的标准模式，不涉及 hybrid `ha_storage`。

![Recovery Mode 与常规 Vault 进程的对比：常规模式下所有子系统正在运行、客户端走标准 API；Recovery Mode 仅剩 sys/raw 一条通道，且仅由 recovery token 鉴权](/images/ch6-integrated-storage/recovery-mode-surface.png)

---

## 12. 离线快照：`operator raft snapshot save / restore / inspect`

`peers.json` 与 Recovery Mode 都是"出现严重故障时才使用"的工具，正常运维中真正高频用到的、与 Integrated Storage 数据安全直接相关的命令是 `vault operator raft snapshot`。这一组命令在第 5.7 节"集群底层运维手术刀"中已经从 CLI 视角介绍过，本节仅补充与 6.4 主题强相关的两个事实：

- `vault operator raft snapshot save <file>` 把当前 Raft cluster 状态写入快照文件；该快照文件可以被 `snapshot restore` 用于将 Vault 还原到当时的状态。`snapshot inspect` 可以检查一份快照文件并打印 key 数量与占用空间。**只有当 Vault 使用 Integrated Storage 时，这套快照命令才能保存与恢复 Vault 数据**；若 raft 仅作 high-availability storage，则不支持 snapshot。
- 在 quorum 永久丢失但仍存在一份近期快照可用时，正确的操作顺序通常为：先按 §10 使用 `peers.json` 把成员关系收敛至一台幸存节点；再在该节点上使用 `snapshot restore` 把数据恢复至上一个已知良好状态；之后向集群补充 join 新的干净节点。

> Snapshot 不是 Recovery Mode 的替代品——前者用于"数据回滚"，后者用于"进程根本无法启动"。两者解决的问题维度不同，配置时通常会**同时**准备：使用 cron / Kubernetes CronJob 自动定期 `snapshot save` 是 Vault 生产部署的最低标配。

---

## 13. 关于 Redundancy Zones（仅企业版，了解即可）

[Redundancy Zones](https://developer.hashicorp.com/vault/docs/enterprise/redundancy-zones) 是 Autopilot 的一个**企业版功能**：它在每个可用区（availability zone）部署一台 voter 与若干 non-voter；当某个 zone 的 voter 失效时，同 zone 内的 non-voter 会被自动 promote 为 voter；若整个 zone 丢失，会从其它 zone 的 non-voter 中 promote 一台来维持 quorum。这些 non-voter 同时也起到读扩展的作用。

Redundancy Zones 在节点配置文件中通过 `storage "raft" { ... autopilot_redundancy_zone = "zone-a" }` 这样的字段声明；该字段是可选的字符串，被汇报给 Autopilot 用于增强可扩展性与韧性。

> 本课程**不**针对 Redundancy Zones 设计动手实验——因为它要求 Vault Enterprise 1.11.0 或更高版本（）。在此提及它是为了让学员在阅读官方 Autopilot 文档与 `autopilot state` 输出中看到 "Redundancy Zone" / "Optimistic Failure Tolerance" 等字样时不致困惑。

---

## 14. 本节小结

- `storage "raft"` + 显式 `cluster_addr` 是 Integrated Storage 的最小必要骨架；节点之间通过 cluster port 进行 mTLS 通信，证书由 Vault 自身生成与轮换。
- 节点 join 阶段会**例外地**先经过 API port 完成 challenge / response 鉴权，证书交换完成后再切回 cluster port；这是 Vault 社区版唯一一处节点之间通过 API port 通信的场景。
- Autopilot 在 Vault 1.7+ 默认启用，开源版可用的能力是 Server Stabilization、Dead Server Cleanup 与 State API 三项；前者默认即生效，后者必须显式启用。
- Server Stabilization Time（默认 10 秒）让新 voter 节点必须先以 non-voter 身份保持该段时长，避免落后节点被立即赋予投票权而造成状态机倒退风险。
- Dead Server Cleanup 必须同时设置 `cleanup_dead_servers=true` 与 `min_quorum`；`dead_server_last_contact_threshold` 是触发清理的阈值（默认 24 小时，**不应轻易调低**）。
- 在 quorum 永久丢失时，按"幸存节点 + `peers.json`"的方式重组集群；最坏情况下可以仅依靠一台幸存节点恢复，但该路径会牺牲一致性。
- Recovery Mode 是 `vault server -recovery` 的进入方式，专门面向"Vault 进程根本无法启动"的兜底场景；它会自动将集群缩减为 1 节点，仅暴露 `sys/raw`，且仅可由 recovery token 鉴权——使用后必须再走 raft 重组流程才能回到正常服务。
- 离线 raft 快照（`operator raft snapshot save / inspect / restore`）是与本节直接相关的高频命令，建议在生产部署中以 cron / CronJob 形式自动周期执行。

本节配套的动手实验在严格的"零真实云、零企业版授权"约束下，让学员在一台 Killercoda 主机上通过端口区分启动 3 个节点的 raft 集群，依次演练：组装集群、通过 `autopilot state` 进行观察、把 Server Stabilization Time 调高后再添加节点观察 `Voter=false` → `Voter=true` 的过渡、启用 Dead Server Cleanup 后让 Autopilot 自动剔除被 kill 的节点、使用 `snapshot save` 创建快照、然后通过 quorum 永久丢失 + `peers.json` 重组路径完整地把数据从快照中恢复回来。
