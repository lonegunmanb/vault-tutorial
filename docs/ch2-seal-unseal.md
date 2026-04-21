---
order: 22
title: 2.2 封印与解封（Seal/Unseal）机制的密码学底层原理
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.2 封印与解封（Seal/Unseal）机制的密码学底层原理

> **核心结论**：Vault 启动后默认处于"封印"状态——磁盘上的数据是加密的，进程内存中没有任何能解密这些数据的密钥。"解封"不是登录，而是**通过密码学协议将解密能力临时注入进程内存**。理解这一点，是理解 Vault 一切安全保障的起点。

## 1. 为什么需要"封印"这个概念

### 1.1 Vault 必须假设的威胁模型

按照官方 [Security Model](https://developer.hashicorp.com/vault/docs/internals/security) 与 [Vault Architecture](https://developer.hashicorp.com/vault/docs/internals/architecture) 文档的明确表述，Vault 的安全设计建立在一个**非常悲观**的假设之上：

> **存储后端、底层主机、网络通路、虚拟化平台——这些"基础设施"都不被信任。**

这不是夸张，而是现代云原生部署的真实写照。来看几个具体的攻击场景：

**场景 A：云平台快照与虚拟机克隆**

你在 AWS / Azure / GCP 上跑着一台 Vault 服务器。云厂商的运维（出于内部维护、合规取证、甚至账号被滥用）可以**在你完全不知情的情况下**：

1. 给你的虚拟机打一个磁盘快照
2. 把这个快照挂载到另一台虚拟机上启动

如果 Vault 进程的解密密钥能在启动时从磁盘自动加载（就像很多传统数据库的"密码写在配置文件里"那样），那么这个克隆出来的 Vault 实例**一启动就是完全可用的**——攻击者立刻能用任意 Token 读出所有机密的明文。这等同于把整个机密库直接交给了攻击者。

**场景 B：存储后端被独立窃取**

Vault 用 Consul / Raft / 文件系统作为存储后端。这些后端常常出于备份、容灾、审计的目的被复制到第三方系统：

- 数据库管理员把 Consul 的 BoltDB 文件复制到测试环境调试
- 备份系统每天把 `/opt/vault/data` 同步到对象存储
- 一个误配置的 `find` 命令把 Raft 数据目录打包进了某个公开的 issue 附件

如果存储后端里的数据是**明文**的，上述任何一个事件都意味着机密泄漏。

**场景 C：内核 / Hypervisor 层面的内存窥探**

云厂商的 hypervisor 理论上有能力 dump 任何虚拟机的内存。这部分风险 Vault 无法完全消除，但可以**最小化暴露窗口**——只让密钥在"被解封到主动封印或重启"这段时间里出现在内存中。

### 1.2 封印机制就是为了堵死这些场景

Vault 用一层叫做 **Barrier（屏障）** 的对称加密包住所有写入存储后端的数据（KV 机密、策略、租约、Token 元数据、认证方法配置——**没有任何例外**）。Barrier 的核心特性：

- **存储后端只能看到密文**：场景 B 中即使整个数据目录被复制，没有 Barrier 密钥也是一堆无意义的二进制，对应官方 Security Model 文档里的 "the storage backends are considered untrusted by design"
- **Barrier 密钥在 Vault 进程启动时绝不在内存中**：场景 A 中克隆出来的虚拟机启动后，Vault 进程会立刻进入 `Sealed=true` 状态——它知道自己有数据要保护，但它**自己也读不出来**，必须等待外部"解封协议"把密钥送进来
- **进程内存是 Barrier 密钥的唯一活体存放地**：场景 C 中密钥的暴露时间窗等于进程的"已解封运行时长"，主动 `vault operator seal` 或重启进程都会让密钥从内存中蒸发，磁盘上则**永远没有过密钥的明文副本**

这种"启动即不可用、必须显式注入解密能力"的状态，就是 **Sealed（封印）**。"解封"不是登录，而是**通过密码学协议把解密能力**临时**放进内存的过程**。

### 1.3 一个被低估的设计推论

正因为 Vault 把"启动后自动可用"这条路彻底堵死了，所以：

- **磁盘备份可以放心地交给第三方**——它们就是密文，不增加攻击面
- **虚拟机被云厂商克隆不会立刻造成泄漏**——克隆出来的实例不会自动解封
- **快照、镜像、容器层都可以纳入常规 CI/CD 流程**——只要不把 Unseal Key 一起放进去

这是 Vault 与"用配置文件里的密码加密数据库"这类传统方案的**根本性差异**。代价是运维上的复杂度（每次重启都要解封），但换来的是一个可以诚实地告诉合规审计员"我们的备份系统没有访问机密的能力"的安全模型。Auto-Unseal（第 4 节）就是在不破坏这个安全模型前提下，把"解封"这一步从"人到场"改成"调用一个外部 KMS"——但**密钥本身依然不写入 Vault 自己的存储**。

## 2. 三层密钥体系：Vault 加密的"洋葱模型"

按官方 [Security Model](https://developer.hashicorp.com/vault/docs/internals/security) 的描述，Vault 的密钥层级是一个三层结构（也常被称为"加密三明治"）。理解这三层的职责分工，才能看懂解封过程到底在做什么。

```
┌─────────────────────────────────────────────────────────────┐
│  数据加密密钥 (DEK / Encryption Key)                         │
│  ─ 用 AES-256-GCM 实际加密每个存储条目                       │
│  ─ 持久化在存储后端，但本身被 Root Key 加密                  │
│  ─ 可通过 vault operator rotate 在线轮转                     │
└──────────────────────▲──────────────────────────────────────┘
                       │ 加密保护
┌──────────────────────┴──────────────────────────────────────┐
│  根密钥 (Root Key / 旧称 Master Key)                         │
│  ─ 加密 DEK 的"密钥的密钥"                                   │
│  ─ 同样持久化在存储后端，但被"封印密钥"再加密一次            │
│  ─ 可通过 vault operator rekey 重生 + 重新分发分片           │
└──────────────────────▲──────────────────────────────────────┘
                       │ 加密保护
┌──────────────────────┴──────────────────────────────────────┐
│  封印密钥 (Unseal/Seal Key)                                  │
│  ─ Shamir 模式：被切成 N 份，需 K 份重组                     │
│  ─ Auto-Unseal 模式：托管给 KMS / HSM，开机自动调用          │
│  ─ 这是"信任根"——它从不持久化在 Vault 自己的存储里          │
└─────────────────────────────────────────────────────────────┘
```

**为什么要做三层而不是直接用一个密钥加密所有数据？**

- **轻量轮转**：日常的 DEK 轮转只需重新加密被 Root Key 保护的 DEK 自身，不必重写所有历史数据
- **职责分离**：DEK 服务于"加密性能"，Root Key 服务于"密钥治理"，Unseal Key 服务于"信任建立"
- **可替换的信任根**：Auto-Unseal 把最外层的 Unseal Key 委托给云厂商 KMS 或 HSM，而不动内层结构

## 3. Shamir's Secret Sharing：让"开门"成为多人协作

Shamir 的秘密分享（Shamir's Secret Sharing，SSS）是 Vault 默认的封印实现。它的数学基础是**有限域上的多项式插值**：任意 K 个点可以唯一确定一条 K-1 次多项式，少于 K 个点则给不出任何关于该多项式的有效信息。Vault 用这个性质把 1 个 Unseal Key 拆成 N 个分片（默认 N=5），并要求至少 K 份（默认 K=3）才能重组。

```
                    Unseal Key (256-bit 随机)
                          │
            ┌─────── Shamir Split (N=5, K=3) ───────┐
            ▼                                        ▼
  ┌─────────┬─────────┬─────────┬─────────┬─────────┐
  │ Share 1 │ Share 2 │ Share 3 │ Share 4 │ Share 5 │
  └─────────┴─────────┴─────────┴─────────┴─────────┘
       │         │         │         │         │
   持有人 A  持有人 B  持有人 C  持有人 D  持有人 E
                                          (互不相同的人)

  解封一次 = 任意 3 人到场 → 重组 Unseal Key → 解密 Root Key
                                          → 解密 DEK → 进入可用状态
```

**这一机制保障了三件事**：

1. **没有任何单一人员能独自解封 Vault**——即使他是"管理员"
2. **少于 K 份分片不会泄漏 Unseal Key 的任何信息**（信息论意义上的安全）
3. **支持优雅降级**：N-K 份分片丢失 / 损坏仍可恢复（默认 5/3 容许 2 份失效）

> 详细参数与 Recovery Key 的差异见 [`vault operator init`](https://developer.hashicorp.com/vault/docs/commands/operator/init) 与 [`vault operator unseal`](https://developer.hashicorp.com/vault/docs/commands/operator/unseal)。

## 4. Auto-Unseal：把"信任根"委托给 KMS / HSM

手动 Shamir 解封的痛点很现实：服务器每次重启都需要 K 个人到场提供分片。在自动伸缩、容器化、多可用区的现代部署下，这是不可持续的运维负担。

[Auto-Unseal](https://developer.hashicorp.com/vault/docs/configuration/seal) 的解法是把最外层的封印密钥**完全托管给一个外部信任根**——通常是云厂商 KMS（AWS KMS、Azure Key Vault、GCP KMS）或物理 HSM。Vault 启动时直接通过 IAM / 工作负载身份调用 KMS 的 Decrypt API，把已加密的 Root Key 解密出来，整个过程无需人工干预。

| 维度 | Shamir Seal | Auto-Unseal (Cloud KMS / HSM) |
| :--- | :--- | :--- |
| **谁持有信任根** | N 个人类操作员各持一份分片 | 云厂商 KMS / 物理 HSM |
| **重启后何时可用** | 等待 K 人到场提供分片 | 启动后秒级自动可用 |
| **运维负担** | 高（每次重启都需协调人） | 低（无人值守） |
| **信任根的失窃风险** | 分片被收买 / 内部勾结 | KMS 凭据泄露 / IAM 配置错误 |
| **典型场景** | 人员可随时到场的小规模部署、合规要求多人控制 | 自动伸缩、多 AZ、容器化、灾难恢复 |
| **Recovery Keys** | 不适用（Unseal Key 本身就是分片） | 仍生成一组用于灾难恢复的 Shamir 分片 |

> Auto-Unseal 模式下额外生成的 **Recovery Keys** 用于 `generate-root`、`rekey` 等高敏操作的多人授权，而不是日常解封。

## 5. Sealed 状态下 Vault 还能做什么

封印不是"完全瘫痪"，而是"业务功能全停、运维入口可用"。处于 Sealed 状态时：

| 类别 | 可用性 |
| :--- | :--- |
| 读取 / 写入 KV、PKI 等机密 | ❌ 不可用 |
| 登录获取新 Token | ❌ 不可用 |
| 续约 / 撤销已有租约 | ❌ 不可用 |
| `vault status`（查看封印状态） | ✅ 可用 |
| `vault operator unseal`（提交分片） | ✅ 可用 |
| `vault operator init`（首次初始化） | ✅ 可用（且仅在未初始化时） |
| 健康检查端点 `/sys/health` | ✅ 可用（返回 503，含 `sealed: true`） |

这种设计让运维人员可以在不解封的情况下进行集群健康判断与解封协作，符合"最小可用面"的安全工程原则。

## 6. 主动封印：紧急停机的"安全开关"

`vault operator seal` 是一个非常重要、却经常被忽视的命令。它的作用是**主动把已解封的 Vault 立刻拉回封印状态**，等价于一次"全局熔断"。

适用场景：

- **检测到入侵 / 凭据泄露**：立刻让所有进行中的操作失败，争取处置时间
- **计划停机维护**：在底层基础设施操作前显式封印，避免半状态
- **合规演练**：定期验证"全员到场重新解封"的流程仍然可用

需要明确的是：主动封印**不会丢失任何持久化数据**——Barrier 加密层依然原样躺在存储后端，一旦重新解封即可恢复全部状态。这与 Dev 模式的"重启即数据归零"截然不同（这也是 2.1 节中我们亲手验证过的）。

## 7. 密钥轮转：Rotate vs Rekey 的关键区分

Vault 的两个轮转命令长得像，但作用在密钥树的不同层级，混用会带来真实的运维事故：

| 命令 | 作用层级 | 影响 | 是否需要分片授权 |
| :--- | :--- | :--- | :--- |
| `vault operator rotate` | **数据加密密钥（DEK）** | 生成新的 DEK，新写入的数据用新 DEK 加密；老数据继续可用 | 否（已解封的管理员即可执行） |
| `vault operator rekey` | **封印密钥（Unseal Key）+ 其分片** | 重新生成 Unseal Key，重新切分分片，**分发给新的持有人** | 是（必须达到当前阈值） |

参考 [Rekeying & rotating](https://developer.hashicorp.com/vault/tutorials/operations/rekeying-and-rotating) 教程，典型组合策略是：

- **DEK Rotate**：高频，可定期自动执行（如每月），降低单一密钥的暴露窗口
- **Unseal Rekey**：低频，但必须在人员变动时执行（持有分片的同事离职、并购整合等）

## 8. 实验室预告

第 1 章 `what-is-vault` 的实验里，你已经亲手完成过一次完整的 init + 三轮 Shamir 解封 + 主动 seal + 重新解封 + Barrier 密文观察。本节的动手实验**不再重复这些基础流程**，而是聚焦在 2.2 节新引入的、`what-is-vault` 没覆盖到的概念上：

1. **Shamir 阈值机制的深入观察**：Nonce 字段如何防止并发解封劫持、任意 K 份分片的等价性、少于 K 份提交时 Vault 处于"卡住"状态的真实表现
2. **`vault operator rotate`（DEK 轮转）**：执行后老数据是否仍可读、`sys/key-status` 字段如何变化
3. **`vault operator rekey`（Unseal Key 重切分）**：把 5/3 改成 7/4，亲眼验证老分片彻底失效、必须用新分片解封，并理解为什么 rekey 必须先用当前阈值授权
4. **吊销初始 Root Token**：生产环境收尾的标准动作，验证为什么 [Tokens 文档](https://developer.hashicorp.com/vault/docs/concepts/tokens#root-tokens)要求"初始 Root Token 用完即销毁"

为了节省时间，实验环境会自动帮你预先完成 Vault 启动、init、解封、写入两条机密——你一进入终端就面对一个已经在跑、有数据的真实 Vault 实例。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-seal-unseal" title="实验：Shamir 解封、封印恢复与密钥轮转" />

## 参考文档

- [Vault Architecture — Internals](https://developer.hashicorp.com/vault/docs/internals/architecture)
- [Security Model — Internals](https://developer.hashicorp.com/vault/docs/internals/security)
- [Seal/Unseal — Concepts](https://developer.hashicorp.com/vault/docs/concepts/seal)
- [Seal Configuration](https://developer.hashicorp.com/vault/docs/configuration/seal)
- [`vault operator init` 命令参考](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [`vault operator unseal` 命令参考](https://developer.hashicorp.com/vault/docs/commands/operator/unseal)
- [`vault operator seal` 命令参考](https://developer.hashicorp.com/vault/docs/commands/operator/seal)
- [`vault operator rekey` 命令参考](https://developer.hashicorp.com/vault/docs/commands/operator/rekey)
- [`vault operator rotate` 命令参考](https://developer.hashicorp.com/vault/docs/commands/operator/rotate)
- [Rekeying & Rotating Vault — 教程](https://developer.hashicorp.com/vault/tutorials/operations/rekeying-and-rotating)
