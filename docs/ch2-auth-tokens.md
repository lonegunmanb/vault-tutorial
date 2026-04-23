---
order: 24
title: 2.4 认证（Authentication）与令牌（Tokens）树状层级关系本质
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.4 认证（Authentication）与令牌（Tokens）树状层级关系本质

> **核心结论**：Vault 里**唯一**真正用来鉴权的东西是 Token。所有外部
> 认证方法（GitHub / LDAP / AppRole / Kubernetes / OIDC …）都只做一件
> 事：**把外部身份翻译成一个 Vault Token**。理解 Token 的内部数据结构
> （类型、父子树、accessor、TTL/period）就等于理解了 Vault 鉴权的全部。

参考：
- [Authentication — Concepts](https://developer.hashicorp.com/vault/docs/concepts/auth)
- [Tokens — Concepts](https://developer.hashicorp.com/vault/docs/concepts/tokens)

---

## 1. 一切外部认证方法都是「Token 工厂」

Vault 文档里把 auth 描述得很直接：

> Authentication in Vault is the process by which user or machine supplied
> information is verified against an internal or external system.
> Upon authentication, **a token is generated**.

注意第二句话——**任何认证方法的最终产物都是一个 Token**。GitHub
auth method 帮你验证 GitHub PAT，验通过之后**生成一个 Vault Token 给你**；
Kubernetes auth method 验你的 ServiceAccount JWT，验通过之后**生成一个
Vault Token 给你**；OIDC 一路 redirect 转完之后，**还是生成一个 Vault
Token 给你**。

这就给后续的所有讨论定下了基调：

- 整个 Vault 系统里**只有 Token 一种鉴权凭据**；
- 所有外部认证方法都只是 Token 的「来源」，一旦 Token 颁发出去，
  **它的行为完全由 Token 自身的元数据（policies、ttl、period、parent 等）决定**，
  不再回去问外部系统。

### 1.1 Token Auth Method 是个特殊存在

> The "token store" is the same as the [token authentication backend].
> This is a special backend in that it is responsible for creating and
> storing tokens, and **cannot be disabled**.

也就是说——其它 auth method 都可以被 `vault auth disable` 干掉，**唯独
`token` 这一个不行**。它就是 Vault 鉴权层的"地基"。其它所有 auth method
都以"我去找 token store 要一个 Token 给你"的方式工作。

理解这一点之后，看上面 `vault login -method=github`、`vault login -method=userpass`
这些命令就有了真正的画面感：它们**最后都归结为往 token store 写入一条
新的 Token 记录**。

### 1.2 `display_name`：Token 的"户籍信息"

每个 auth method 在签发 Token 时会带一个 `display_name` 字段（例如
`github-alice` / `userpass-bob` / `kubernetes-app-svc`）。这个字段：

- **不参与鉴权决策**——policies 才是
- 但会**写进审计日志**和 KV v2 metadata 的 `created_by` 字段
- 用来在事后追溯"是哪个外部身份签的这个 Token"

所以即使 Token 本身只是一串 `hvs.xxxxxx`，你也能从审计层面追到它当初
是哪个外部身份换来的。这是 Vault 在"统一 Token 鉴权"和"保留外部身份
痕迹"之间的折中。

---

## 2. Token 的两大类：service vs batch

这是 1.10 之后被反复强调但仍被很多人忽略的设计。Vault 里 Token 不是
铁板一块，而是有两种**完全不同的实现机制**。

### 2.1 前缀就告诉你它是谁

> | Token type      | New format        |
> | --------------- | ----------------- |
> | Service tokens  | `hvs.<random>`    |
> | Batch tokens    | `hvb.<random>`    |
> | Recovery tokens | `hvr.<random>`    |

你以后在日志里、命令行里看到 `hvs.` 开头的——它**有完整生命周期管理
（renew/revoke/parent/accessor/cubbyhole）**；看到 `hvb.` 开头的——
它是**一段加密自包含 blob，没有任何服务端状态**。

### 2.2 服务端状态的有无是唯一关键差别

| 维度 | Service Token (`hvs.`) | Batch Token (`hvb.`) |
| --- | --- | --- |
| 是否在 lease 表里跟踪 | ✅ | ❌（自包含 JWT-like blob） |
| 可以续约 | ✅ | ❌（到期硬过期） |
| 可以单独 revoke | ✅ | ❌（只能等过期或撤父 token） |
| 可创建子 Token | ✅ | ❌ |
| 有 accessor | ✅ | ❌ |
| 有 cubbyhole | ✅ | ❌ |
| 可作为 root token | ✅ | ❌ |
| 可设 periodic | ✅ | ❌ |
| 创建成本 | 重（多次磁盘写） | 极轻（无磁盘写） |
| 跨性能复制集群可用 | 否 | 是（仅 orphan） |

### 2.3 选型直觉

- **要长期持有 + 需要后台续约 / 紧急吊销 / 子 Token / cubbyhole 暂存** →
  service token
- **高并发短任务，每秒上万次签发，用完即抛，无需 revoke** →
  batch token（典型如 Kubernetes pod 启动批量拉密钥、CI 流水线 job）

文档里专门提醒：**batch token 创建成本极低**，不写磁盘 = 不占 Raft 日志，
所以 performance standby 节点也能直接签——这是 Vault 在大规模 K8s 集群
里能撑住每秒几万次认证请求的关键架构选择。

### 2.4 Batch token 的 lease 行为很特殊

文档里那一句要单独拎出来：

> Leases created by batch tokens are constrained to the remaining TTL of
> the batch token and, **if the batch token is not an orphan, are tracked
> by the parent**.

也就是说，**batch token 自己虽然没有 lease 记录，但它通过你的动态机密
拉出来的 lease 会被挂到它的父 service token 上**。父 token 一被 revoke，
batch token 拉的所有动态机密也会跟着被回收。这就是 §3 里讲的"Token 树
级联撤销"在 batch token 场景下的特殊变体。

---

## 3. Token 树：父子层级与级联撤销

这是 2.3 章节"Token revoke 时级联清理子租约"的**真正底层数据结构**。

### 3.1 默认行为：父子串成树

> Normally, when a token holder creates new tokens, these tokens will be
> created **as children** of the original token; tokens they create will
> be children of them; and so on. **When a parent token is revoked, all
> of its child tokens — and all of their leases — are revoked as well.**

形式化一点画出来：

```
root token
  └── ops-team-token (policy=ops)
        ├── deploy-token-A (policy=deploy)   --- lease: db/creds/x  ← 父子链
        ├── deploy-token-B (policy=deploy)
        └── debug-token (policy=read-only)
              └── nested-token-1
              └── nested-token-2
```

`vault token revoke ops-team-token` 一句话——**整棵子树连同它们签出的
所有动态机密 lease 全部被销毁**。这就是 Vault 提供的"按身份维度的一键
吊销爆炸半径"能力。

### 3.2 设计意图：堵死「无限分裂逃避吊销」

文档里那句关键解释：

> This ensures that a user cannot escape revocation by simply generating
> a never-ending tree of child tokens.

如果没有"父被撤 → 子全撤"的规则，一个攻破的 service account 完全可以
"今天晚上 11 点之前给自己派生 1 万个子 token，然后明天我自己被发现被撤
也无所谓——那 1 万个子孙 token 还活着"。Vault 的 token 树语义从根上
封死了这条路。

### 3.3 Orphan token：故意打破链路

但是有些场景里你**就是不希望** "父被撤子也死"——例如：

- 一个长期运行的 daemon，它的初始 root/admin token 用完就要销毁，但
  daemon 自己拿到的 token 不能跟着死；
- 跨 performance replication 集群使用的 batch token——非 orphan 的
  batch token 没办法在另一个集群验证父 token 的存在性，所以**只有
  orphan 才能跨集群**。

文档列出了 4 种创建 orphan token 的合法路径：

1. `auth/token/create-orphan` 端点（需要 write 权限）
2. `auth/token/create` + `no_parent=true`（需要 sudo 或 root）
3. 通过预先配置的 token store role
4. **任何非 token 的 auth method 登录**（`vault login -method=userpass` 等）

第 4 条尤其关键——它意味着**所有外部认证方法签出来的 Token 默认都是
orphan**。这非常合理：这些 Token 的"父"实际上是外部身份系统，根本不
存在于 Vault 内部的 token 树里。所以你在 GitHub 那边 revoke 不了一个
Vault token。

### 3.4 一个危险但有用的中间形态：`revoke-orphan`

> Users with appropriate permissions can also use the `auth/token/revoke-orphan`
> endpoint, which revokes the given token but rather than revoke the rest
> of the tree, **it instead sets the tokens' immediate children to be orphans.**

这是个中级管理员要会的"外科手术"工具：撤掉一个中间节点，但**让它的
直接子节点变成各自子树的根**。生产里很少用，但当你需要"干掉某个被
入侵的中间层 service account，又不想殃及它管的几百个下游应用 token"时，
这是唯一的选择。文档自己都加了 "Use with caution!" 警告。

---

## 4. Accessor：在不持有 Token 的前提下管理 Token

这是 Vault token 设计里**最优雅、也最容易被忽视**的一个特性。

### 4.1 创建 Token 时同时返回 accessor

每次 `vault token create` 的输出里有两个字段：

```
token             hvs.CAESI...REAL_TOKEN_HERE...
token_accessor    XzLnJq8KsRf2WyHaNcVbMpG3
```

- `token` 是真正的鉴权凭据，握住它 = 拥有这个 Token 的全部权限
- `token_accessor` 是一个**只能引用、不能鉴权**的句柄

### 4.2 Accessor 能做的 4 件事

文档明确列出：

1. Look up a token's properties **(not including the actual token ID)**
2. Look up a token's capabilities on a path
3. Renew the token
4. Revoke the token

注意第 1 条的小字——**通过 accessor 查不出 token 本身**。这是单向的：
有 token 能算出 accessor，但**有 accessor 算不出 token**。

### 4.3 Accessor 解决的真实问题

文档举了个 Nomad 的例子：

> A service that creates tokens on behalf of another service (such as the
> Nomad scheduler) can store the accessor correlated with a particular
> job ID. When the job is complete, **the accessor can be used to instantly
> revoke the token** given to the job and all of its leased credentials.

把它翻译成更通用的话：

> 一个调度系统给每个 job 都从 Vault 派一个 token。**调度系统自己不应该
> 存这个 token**——存了就是机密泄漏面。但它**可以放心地存 accessor**，
> 因为 accessor 单独拿到也只能看属性 / 撤销，没法用来读密钥。

这是 Vault 在"集中管控"和"最小机密暴露面"之间提供的一种非常优雅的
妥协：调度系统拥有"一键撤掉某个 job 的所有凭据"的能力，但**它本身
没有那些凭据的明文**。

### 4.4 列 token 的唯一方式：列 accessors

> The only way to "list tokens" is via the `auth/token/accessors` command,
> which actually gives a list of token accessors.

这是个值得单独记一下的细节——**Vault 里没有"列出所有 token"的 API**。
最接近的也只是"列出所有 accessor"。两个原因：

- token 本身是**敏感的鉴权凭据**，列出来等于全员泄密
- accessor 不能用来鉴权，但**能用来撤销**——在事故响应里这是个核武器

文档同时提醒：列 accessors 也是个相当危险的端点（能撤所有 token =
全员踢下线 = DoS），生产里通常用 policy 把它锁死给少数审计账号。

---

## 5. TTL、Periodic Token 与 explicit max_ttl

Token 的生命周期有三种模式，要分别理解。

### 5.1 一般情况：跟挂载点 max_ttl 跑

> The token's lifetime since it was created will be compared to the maximum
> TTL. This maximum TTL value is **dynamically generated** and can change
> from renewal to renewal.

最大 TTL 是三个值的最小者：

1. 系统级 max TTL（默认 32 天，配置文件可改）
2. auth method 挂载点的 max_ttl（mount tuning）
3. 该 auth method 自己的 role/group/user 配置

**文档专门强调一句**：(2)/(3) 在续约时可能临时改了，所以**每次续约后必须
看返回值的 TTL 是不是真的延长了**——如果没延，说明已经撞天花板，应用
应该重新走完整 login 流程。这条建议在写 token-renew goroutine 时是关键。

### 5.2 `explicit_max_ttl`：硬天花板

```bash
vault token create -explicit-max-ttl=24h ...
```

设了之后，**这个 token 永远活不过 24 小时**——不管系统 max_ttl 多大、
不管挂载点配置怎么变、**不管是不是 periodic token**。这是 token 上的
"死刑日"，不可逾越。

### 5.3 Periodic Token：除了 root 之外唯一可"无限续命"的 token

> In some cases, having a token be revoked would be problematic — for
> instance, if a long-running service needs to maintain its SQL connection
> pool over a long period of time. In this scenario, a periodic token can
> be used.

Periodic token 的关键差别：

- **每次签发或续约，TTL 都被重置回配置的 period**（例如 1h）
- **没有挂载点 max_ttl 的约束**——只要你在 period 之内续约，就能永远活下去
- 唯一能让它死的是 `explicit_max_ttl` 或主动 revoke

设计意图——文档里这段说得很明白：

> as long as the system is actively renewing this token — in other words,
> as long as the system is alive — the system is allowed to keep using
> the token.

也就是说：**应用还活着 → 持续续约 → token 活着；应用挂了 → 不续约了 →
period 时间一过 token 自然死亡**。这就解决了"长跑 daemon 怎么办" 的
问题：你给它一个 period=1h 的 token，让它每 30 分钟续一次。它正常跑
就一直活，它崩了一小时内 token 就消失，泄露窗口可控。

### 5.4 Root Token 的特殊地位

> Root tokens are tokens that have the `root` policy attached to them.
> Root tokens can do **anything in Vault. Anything**.

文档自己都用了"Anything. Anything." 这种少见的强调写法。它们是 Vault
里**唯一可以 TTL=0（永不过期）的 token**。

只有 3 种合法方式得到 root token：

1. `vault operator init` 时初始返回的那个（无过期时间）
2. 用另一个 root token 创建（**带过期时间的 root 不能创建无过期的 root**——
   防止有限权降级被绕过）
3. `vault operator generate-root` + 一组 unseal key 持有人共同授权

文档非常明确地建议：

> Root tokens are useful in development but should be **extremely
> carefully guarded** in production. The Vault team recommends that
> **root tokens are only used for just enough initial setup ... or in
> emergencies, and are revoked immediately after they are no longer needed.**

2.2 章节实验最后一步"撤销初始 root token"对应的就是这条。生产里你应该
完全没有任何长期存在的 root token——需要时用 `generate-root` + 多人
共同授权临时生成一个，用完立刻 revoke。

---

## 6. CIDR 绑定

`vault token create -bound-cidrs=10.0.0.0/8,192.168.1.5/32 ...`

绑了之后这个 token **只能从指定 IP 段发起请求**，从其它 IP 用就直接 403。
这对 service token 是个非常便宜的横向防御措施——一份被泄漏的 token
拷到攻击者机器上也用不了，因为源 IP 对不上。

唯一例外：**没有过期时间的 root token 不受 CIDR 绑定影响**，因为它代表
"超级权限，必须能在任何地方做应急操作"。但带 TTL 的 root token 仍然受 CIDR 约束。

---

## 7. 一张图总览本节所有概念的关系

```
+--------------------------------------------------------------------+
|                      Vault Token Store (always on)                  |
|                                                                     |
|    +-------- token tree ---------+      +--- accessor index ---+   |
|    |                             |      |                      |   |
|    |  root (TTL=0)               |      |  accessor → token    |   |
|    |   ├── service A             |      |  (单向引用，不能反查)  |   |
|    |   │     ├── service A.1     |      |                      |   |
|    |   │     ├── batch B (orphan)|      +----------------------+   |
|    |   │     └── service A.2 ──→ leases (在 expiration manager 里) |
|    |   └── service C (orphan)    |                                  |
|    |         └── service C.1     |                                  |
|    +-----------------------------+                                  |
|                                                                     |
|    所有外部 auth method (userpass, github, k8s, oidc, ...)          |
|    登录后都在这里写入一条 (默认) orphan service token                |
+--------------------------------------------------------------------+
```

这张图能让你看清几个关键关系：

- 外部 auth method ≠ Token 本身，它只是 Token 的"工厂入口"
- Token 之间的父子关系**只在内部 token tree 里存在**
- accessor 是另一套**单向索引**，提供"知道引用 / 能撤销 / 但拿不到 token"的安全句柄
- 动态机密的 lease（2.3 章）挂在签发它的 service token 上，构成了"撤
  父 token = 撤所有子 token = 撤所有目标系统侧账号"的完整级联链

---

## 8. 实验室预告

本节配套的动手实验把上述每个反直觉点都跑一遍：

1. **任何 auth method 都是 Token 工厂**：启用 userpass，登录后看
   `display_name` / 默认 orphan / `hvs.` 前缀；
2. **Token 树与级联撤销**：手工搭一棵 3 层树，撤中间节点，看子孙全死；
   同样的树，对中间节点用 `revoke-orphan`，看直接子节点变 orphan、
   不再被殃及；
3. **Accessor 的单向引用**：用 accessor 查属性、查 capabilities、
   revoke——但**永远拿不到 token 本身**；
4. **Periodic vs explicit_max_ttl**：周期 token 反复续命，加了
   `explicit_max_ttl` 之后到点必死；
5. **Service vs Batch**：对比同样的操作（创建子 token / revoke /
   lookup accessor）在两种 token 上的行为差异，验证 §2.2 那张表。

进入实验前请回顾 §3.3（orphan 的 4 种来源）、§4.2（accessor 的 4 种
能力）、§5.3（periodic 的"还活就一直活"语义）这三段。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-auth-tokens" title="实验：Token 树、accessor、periodic 与 service vs batch" />

## 参考文档

- [Authentication — Concepts](https://developer.hashicorp.com/vault/docs/concepts/auth)
- [Tokens — Concepts](https://developer.hashicorp.com/vault/docs/concepts/tokens)
- [Token auth method](https://developer.hashicorp.com/vault/docs/auth/token)
- [`vault token` 命令簇](https://developer.hashicorp.com/vault/docs/commands/token)
- [`vault operator generate-root`](https://developer.hashicorp.com/vault/docs/commands/operator/generate-root)
- [Tokens 教程](https://developer.hashicorp.com/vault/tutorials/get-started/introduction-tokens)
