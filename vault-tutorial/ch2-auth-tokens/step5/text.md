# 第五步：Service vs Batch Token 的本质差异

文档 §2.2 的对比表里列出了 13 项区别。这一步亲手验证最关键的 5 项：
**前缀 / accessor / 子 token / lookup / revoke**。

## 5.1 看前缀

创建两个 token，分别是 service 和 batch 类型：

```bash
SVC=$(vault token create -type=service -policy=default -format=json | jq -r .auth.client_token)
BATCH=$(vault token create -type=batch -policy=default -ttl=10m -format=json | jq -r .auth.client_token)

echo "SVC:   $SVC"
echo "BATCH: $BATCH"
```

注意前缀：

- `SVC` 以 `hvs.` 开头（Vault Service）
- `BATCH` 以 `hvb.` 开头（Vault Batch）

光看前缀就能在日志里立即区分两类 token。

> 注意 batch token 必须显式给 `-ttl`，因为它**不能 renew**——TTL 一定
> 是创建时就定死的。

## 5.2 Accessor：service 有，batch 没有

创建时把整个响应留下来对比：

```bash
vault token create -type=service -format=json | jq '.auth | {accessor, client_token}'
echo "---"
vault token create -type=batch -ttl=10m -format=json | jq '.auth | {accessor, client_token}'
```

batch 的输出里 `accessor` 是 **空字符串**——文档对比表里那一行
"Has Accessors: Yes / No" 的真实含义。这意味着 batch token 没有第 3 步
里讨论的"调度系统持有 accessor 一键吊销"那种治理能力。

## 5.3 子 Token：service 能创建，batch 不能

```bash
echo "Service token 创建子 token:"
VAULT_TOKEN=$SVC vault token create -ttl=5m -format=json | jq -r .auth.client_token

echo "Batch token 尝试创建子 token:"
VAULT_TOKEN=$BATCH vault token create -ttl=5m 2>&1 | tail -3
```

batch 那一句应该报错（拒绝创建子 token）—— 文档对比表里
"Can Create Child Tokens: Yes / No"。

这从根本上决定了 batch token **不可能成为 token 树里的内部节点**——
它要么是叶子，要么是 orphan。

## 5.4 Lookup：service 能查到完整属性，batch 也能但少了字段

```bash
echo "Service token lookup:"
vault token lookup "$SVC" | grep -E "accessor|num_uses|orphan|renewable|type"

echo "---"
echo "Batch token lookup:"
vault token lookup "$BATCH" | grep -E "accessor|num_uses|orphan|renewable|type"
```

batch 的 `renewable` = `false`，`accessor` 为空。

## 5.5 Revoke：service 能撤，batch 不能

```bash
echo "Service token revoke:"
vault token revoke "$SVC" && echo "OK"
vault token lookup "$SVC" 2>&1 | tail -2

echo "---"
echo "Batch token revoke 尝试:"
vault token revoke "$BATCH" 2>&1 | tail -3
```

batch 的 revoke 应该报错（不能单独 revoke）—— 文档原话
"Manually Revocable: Yes / No"。**batch token 的死法只有两种**：

1. TTL 自然过期
2. 它的父 service token 被 revoke（如果它不是 orphan）

第 2 条对应文档原话：

> Leases created by batch tokens are constrained to the remaining TTL of
> the batch token and, if the batch token is not an orphan, are tracked
> by the parent.

## 5.6 batch token 在大规模场景下的真实优势

batch token 看起来"什么都不能干"，那它存在的意义是什么？文档对比
表里有两行揭示了答案：

| 维度 | service | batch |
| --- | --- | --- |
| Cost | Heavyweight; multiple storage writes per token creation | **Lightweight; no storage cost for token creation** |
| Creation Scales with Performance Standby Node Count | No | **Yes** |

一句话：**batch token 不写磁盘，不占 Raft 日志**。这意味着：

- 在 active 节点之外，所有 performance standby 节点都能直接签 batch token
  （service token 必须由 active 节点写 Raft，吞吐严格受限）
- 一个 K8s 集群有 5000 个 pod 启动时同时拉密钥——用 service token 会
  把 active 节点 Raft 写爆；用 batch token 可以把请求**分散到所有
  performance standby 上**

所以 batch token 的设计哲学是："**给我一个用过即抛、TTL 内自包含、
不需要任何治理能力的鉴权凭据，但你要能扛住每秒上万次签发**"。

## 5.7 选型直觉

| 场景 | 用什么 |
| --- | --- |
| 人类 / 长跑应用，需要 renew、需要 revoke、需要 cubbyhole | service |
| K8s pod 启动一次性拉密钥、CI 流水线短 job | batch |
| 跨 performance replication 集群使用 | batch (orphan) |
| 调度系统派给 job 用、需要事后 revoke | service（要 accessor） |

记住一条原则：**你要不要"管"它？**——要管（renew / revoke / 派 child）
就用 service；不管（拿了就用、用完就忘）就用 batch。
