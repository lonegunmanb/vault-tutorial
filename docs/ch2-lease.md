---
order: 23
title: 2.3 租约（Lease）、无感续期与强制撤销的生命周期管理
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.3 租约（Lease）、无感续期与强制撤销的生命周期管理

> **核心结论**：在 Vault 里，每一份**动态机密**和每一个 `service` 类型的 **Token**
> 出生时都被绑了一份"租约（Lease）"。租约不是一个标签，而是一份由 Vault
> 持有的、带 TTL 的承诺：**到点你不来续，我就替你去目标系统把账号删掉。**
> 这是 Vault 与传统密码柜最本质的区别——**机密的失效是 Vault 的责任，
> 不是应用的责任**。

参考：[Lease, renew, and revoke](https://developer.hashicorp.com/vault/docs/concepts/lease)

![lease-overview](/images/ch2-lease/lease-overview.png)

---

## 1. 租约存在的根本理由：把"过期"做成一等公民

传统密码管理（Password Vault / KeePass / 配置中心）里，机密只有两个状态：
**存在**或**不存在**。一条数据库密码被写进去，它就一直有效，直到有人
显式地把它改掉或者删掉。这意味着：

- **轮换是个手动动作**，要么靠运维半夜执行脚本，要么靠合规审计推动；
- **泄露后的爆炸半径无法计算**——你不知道这条密码已经被多少应用拷贝、
  缓存、写进了多少日志；
- **下游目标系统毫无感知**——Postgres 自己根本不知道某个账号是"借出去的"，
  它只认 `pg_user` 表里的那一行。

Vault 引入租约，相当于给每一条秘密**强制加上一个生死簿条目**：

> 「截止到 `expire_time`，这条秘密在 Vault 这里有效。**到时间还没人续，
> 由我去把目标系统里对应的账号销毁。**」

这一句话把过去散在应用、运维脚本、cron job 里的过期逻辑，**收敛到了
Vault 内部一个统一的过期管理器（Expiration Manager）**。所有的审计、
所有的强制撤销、所有的级联回收，都从这个统一中心发出。

---

## 2. 哪些东西有租约，哪些没有

这是初学者最容易踩坑的地方——**不是所有 `vault read` 出来的东西都带租约**。
官方文档里说得很清楚：

| 资源类型 | 是否有租约 | 备注 |
| --- | --- | --- |
| **Dynamic Secret**（database/aws/pki…） | ✅ 必有 | 这是租约机制的核心场景 |
| **`service` 类型 Token** | ✅ 必有 | 也通过 lease 表跟踪 TTL |
| **`batch` 类型 Token** | ❌ 无 | 自包含的 JWT，不在 lease 表里 |
| **KV v1 / KV v2** | ❌ 无 | 虽然响应里可能带 `lease_duration`，**但那只是缓存提示，不是真租约** |
| **Cubbyhole** | ❌ 无 | 跟随 Token 生命周期 |
| **Transit 加解密响应** | ❌ 无 | 无状态操作 |

> KV 引擎里的 `lease_duration` 字段是历史包袱，它只告诉客户端"这条数据
> 你大概可以在本地缓存这么久"，**绝对不要尝试去 renew/revoke 一个 KV
> 返回的"租约"——你拿不到合法的 lease_id**。

理解这张表之后，2.2 章节里 Shamir 演示的 `secret/seal-demo` 就解释清楚了：
它是 KV，所以**永远没有租约**，永远不会"过期"，永远不会被 Vault 主动清理。
真正"用过即焚"的能力，必须走动态引擎。

---

## 3. 租约的内部解剖

每次签发一份动态机密，Vault 都会在自己内部生成一条租约记录。它的关键字段：

```
lease_id        = database/creds/readonly/abc123...    # 路径前缀 + 唯一后缀
issue_time      = 2026-04-22T10:00:00Z
expire_time     = 2026-04-22T11:00:00Z
ttl             = 60m         # 距离 expire 还有多久
renewable       = true
last_renewal    = null
secret          = { username, password, ... }          # 真正的机密载荷
```

### 3.1 `lease_id` 的结构是「按路径前缀」的

注意 `lease_id` 的开头永远是**当初读这个秘密时用的 API 路径**：

```
database/creds/readonly/   <-- 路径前缀
abc123def456...            <-- 该次签发的唯一 ID
```

这不是为了好看，**而是为了支持「按前缀批量撤销」**——这是租约设计里
最强力的一个能力，我们在 §6 里展开讲。

### 3.2 `ttl` 与 `max_ttl` 的两重约束

每次签发或续约，Vault 实际给出的 TTL 是下面三者中的最小值：

```
min(
  调用方请求的 increment,
  挂载点配置的 default_lease_ttl,
  挂载点配置的 max_lease_ttl
)
```

并且**任何一次续约都不能让 `expire_time` 越过 `issue_time + max_ttl`**——
这就是 `max_ttl` 的真实含义：**任何一份机密，从签发那一刻起，
最多只能活这么久，无论续约多少次**。

这是机密管理的"硬天花板"：哪怕一个应用持续在线 30 天且每分钟都续约，
只要 `max_ttl=24h`，第 24 小时一到 Vault 仍然会硬性收回。

---

## 4. 续约（Renew）：把过期时间往后推，但有边界

### 4.1 `increment` 不是"在当前 TTL 之后再加"，而是"从现在开始重新算"

这是另一个反直觉的设计，官方文档里专门提醒：

> The requested increment is **not** an increment at the end of the current
> TTL; it is an increment from the current time.

如果一条租约还剩 30 秒就要过期，调用 `vault lease renew -increment=3600 <lease_id>`
**不是**让它变成「30s + 3600s = 3630s」，而是**直接把 expire_time 设成
"现在 + 3600s"**——也就是说，**调用方完全有能力主动缩短租约**。

这个设计支撑了一个非常优雅的实践：

> **应用拿到一份默认 1 小时 TTL 的凭据，但它只需要用 5 分钟，
> 那就主动 `renew -increment=300`，让 Vault 提前 55 分钟回收资源。**

### 4.2 `increment` 是建议，不是命令

文档还有另一句很重要的话：

> The requested increment is completely advisory.

也就是说：**应用申请 increment=3600，引擎可以只给你 600**。原因可能是：

- 挂载点的 `max_lease_ttl` 限制；
- 离 `issue_time + max_ttl` 已经不到 3600s；
- 引擎自己的策略（例如某些插件强制一次最多续 5 分钟）。

所以应用在续约后**必须读返回值里真实的 `lease_duration`**，按这个数字
来安排下一次续约的时机，而不是按自己请求的数字来。

### 4.3 不可续约的租约

```
renewable = false
```

某些引擎（典型如 PKI 颁发的证书）会把租约标记为不可续约——**到期就是
到期，重新申请一份新的**。这是因为证书的有效期被烧死在了 X.509 结构里，
延长 lease 也改不了证书本身的 NotAfter 字段。

---

## 5. 撤销（Revoke）：让目标系统侧立即生效

撤销是租约机制里**真正具有杀伤力的一招**：

```bash
vault lease revoke <lease_id>
```

执行这一句，Vault 会：

1. 从 lease 表里删除这条记录；
2. **回调对应引擎的 `Revoke` 钩子**——例如 database 引擎会真的连上
   Postgres 执行 `DROP ROLE`、aws 引擎会真的调用 IAM API 删除 access key；
3. 之后再用这份 username/password 去连 Postgres，会被数据库直接拒绝。

注意第 2 步的本质：**Vault 不只是从自己这里"忘掉"了机密，它会主动去
目标系统执行清理动作**。这是租约和「KV 删除一行」最关键的差别——
KV 删了只是 Vault 自己看不到了，**目标系统侧的副作用没人去清理**。

### 5.1 自动撤销 = 过期撤销

> When a lease is expired, Vault will automatically revoke that lease.

也就是说，**没有任何人去手动执行的话，TTL 一到 Vault 后台的过期管理器
也会自动调一次 Revoke**。结果是一样的：Postgres 里那个临时账号被删掉。

这就是 2.4 节 vault-basics step4 实验里 `sleep 75` 之后那个用户消失的
全部原理。

### 5.2 Token 被吊销时的级联清理

> When a token is revoked, Vault will revoke all leases that were created
> using that token.

每一份动态机密在签发时都会**绑定到当时调用方的 Token 上**。当那个 Token
被 revoke（例如用户离职、应用下线、Token TTL 到期），Vault 会**遍历这个
Token 创建的所有租约**，逐个调它们的 Revoke 钩子。

举个例子：

```
root token
  └── app token (policy=app)
        ├── lease: database/creds/readonly/aaa  (Postgres 用户 v-aaa)
        ├── lease: database/creds/readonly/bbb  (Postgres 用户 v-bbb)
        └── lease: aws/creds/dev/ccc            (AWS access key AKIA...)
```

只要一句 `vault token revoke <app-token>`，三个目标系统侧的账号
**全部连带消失**。这是 Vault 在身份级别提供的"一键吊销爆炸半径"能力，
传统密码管理工具里几乎不可能实现。

---

## 6. 前缀撤销：入侵响应的核武器

这是租约机制里最被低估、但在事故响应时最救命的一招：

```bash
# 把 aws/ 下所有路径签出去的所有动态密钥全部撤销
vault lease revoke -prefix aws/

# 把这一个角色历史上签出去的所有凭据全部撤销
vault lease revoke -prefix database/creds/readonly/
```

**它能工作的根本原因，就是 §3.1 里提到的 `lease_id` 的前缀结构。**

设想一个真实场景：你发现一个内部服务被入侵了，攻击者可能拷贝了它过去
2 小时内通过 Vault 拿到的所有 AWS 临时凭据。在传统密码管理里，你需要
手动登录 AWS Console 翻 IAM，一个个去删；用了 Vault 的前缀撤销：

```bash
vault lease revoke -prefix aws/creds/compromised-role/ -force
```

**一句话，Vault 替你登录 AWS，把这个角色历史上签出去的所有还在租约
表里的 access key 全部 IAM DeleteAccessKey 掉**。攻击者手里抄走的那批
凭据，在被这一句撤销之后的下一秒就全部失效。

这就是 §1 里说的「**收敛到统一中心**」的实战价值。

---

## 7. 与"Token 续约"的关系：同一套机制

`service` 类型 Token 也是租约：

```bash
vault token lookup hvs.xxxxx           # 看 ttl
vault token renew                      # 续自己的 token
vault token revoke <token>             # 撤掉，连带它创建的所有 lease
```

它走的是和动态机密**完全相同**的过期管理器。所以 `vault lease lookup`
列租约时，你会同时看到 `auth/...` 开头（Token 租约）和
`database/...` 开头（动态机密租约）两类条目。

> `batch` 类型的 Token 是个例外——它的 TTL 信息直接编码在 Token 本身
> （类似 JWT），Vault 不在 lease 表里跟踪它，因此**不能 renew，也不能
> 单独 revoke**，到时间客户端拿出来用就直接失败。课程后续讲身份模型时
> 还会回到这个区别。

---

## 8. 这一节和 2.4 章节实验的对应关系

`vault-basics` 第 4 步的 Postgres 动态凭据实验已经实战演示了：

- 同一路径两次 `vault read` 拿到不同 lease_id；
- `vault lease renew` 把 TTL 顶满；
- `vault lease revoke` 让 Postgres 里的账号立刻被 Vault 删除；
- TTL 自然到期 = 自动撤销 = 同样的清理动作。

本节配套的实验更进一步——**把上面 §3、§4、§5、§6 里的边界条件全部跑一遍**：

1. **观察 `lease_id` 的前缀结构** 和 `vault list sys/leases/lookup/...` 的层级；
2. **看 `max_lease_ttl` 怎么"压死"`increment`**——演示一份 1h max_ttl 的
   凭据，反复 renew 也无法越过签发时间 + 1 小时；
3. **看续约时 `increment` 是"从现在开始算"**——一份还剩 50s 的租约，
   `renew -increment=10` 之后会**变得只剩 10s**；
4. **看 Token revoke 时的级联清理**——撤掉应用 Token，它签出的所有
   Postgres 用户瞬间从 `pg_user` 里消失；
5. **看前缀撤销在事故响应里的威力**——`vault lease revoke -prefix`
   一句话清空一类角色历史上所有签出去的凭据。

进入实验前请把 §3.2、§4.1、§5.2、§6 这四段重读一遍，实验里出现的"反直觉"
现象都对应着这四段里的某一句话。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-lease" title="实验：租约边界条件——max_ttl 天花板、increment 反向缩短、Token 级联与前缀撤销" />

## 参考文档

- [Lease, renew, and revoke — Concepts](https://developer.hashicorp.com/vault/docs/concepts/lease)
- [Tokens — Concepts](https://developer.hashicorp.com/vault/docs/concepts/tokens)
- [`vault lease` 命令参考](https://developer.hashicorp.com/vault/docs/commands/lease)
- [`vault lease revoke` 命令参考](https://developer.hashicorp.com/vault/docs/commands/lease/revoke)
- [Database secrets engine — Postgres](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
