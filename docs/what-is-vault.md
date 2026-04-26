---
order: 2
title: 什么是现代意义上的 Vault
---

# 什么是现代意义上的 Vault

经过课程介绍中关于"机密蔓生"和"动态防御"的铺垫，你应该已经对 Vault 解决的问题有了感性认识。本章我们正式潜入 Vault 内部：它在 2026 年的云原生生态中处于什么位置？为什么说它不再只是一个"加密保险箱"？以及它的内部数据流是如何在加密层与 API 层之间流转的？

## 1. 从"机密蔓生治理"到"身份联邦"的演进

三年前，Vault 在大多数人的认知里是一个 **集中式的加密机密仓库（Centralized Secret Store）**：把散落各处的数据库密码、API Token、TLS 证书统统塞进 Vault，再通过 ACL 和审计实现治理。这本身已经是巨大进步，但留下了一个未解决的核心难题——**第零号机密（Secret Zero）**。

> 如果应用要从 Vault 读取密码，应用本身就需要先持有一个能登录 Vault 的凭据（比如 AppRole 的 SecretID）。那么这个"凭据的凭据"该如何安全地分发？这就是第零号机密问题。

现代 Vault 的架构哲学已经发生根本性的转向：**从"集中存储静态凭据"演进为"基于身份协议的动态信任协商中枢"**。具体表现在三个方向：

- **工作负载身份联邦（Workload Identity Federation, WIF）**：Vault 不再依赖在自己内部存放云厂商的 Access Key 来访问 AWS / Azure / GCP。它可以用自己签发的 JWT 直接换取云平台的临时凭据，彻底消除"Vault 内部的第零号机密"。
- **Vault 反向充当 OIDC Provider**：Vault 不只是被别的系统当作身份后端来验证用户；它本身可以作为标准的 OIDC IdP，为企业内的自研系统、CI/CD 流水线提供集中式联邦单点登录。
- **从"颁发凭据"到"协商身份"**：现代 Vault 的核心动词是 **协商**，而不是 **存储**。每一次访问都是一次基于密码学的、有时效的身份协商过程。

这三件事我们会在后续章节专门展开，在本章你只需要建立一个心智模型：**Vault 现在是企业的"身份与机密协商中枢"，它的护城河来自密码学协议，而不仅仅是加密存储。**

## 2. Vault 在现代 HashiStack 与云原生零信任生态中的定位

HashiCorp 的全栈愿景把云上自动化分成四层：

| 层面 | HashiCorp 旗舰产品 | 在零信任体系中的角色 |
| :--- | :--- | :--- |
| 基础设施 | Terraform | 声明式地定义"什么资源应该存在" |
| **安全** | **Vault** | **谁能用什么、用多久、如何审计** |
| 网络 | Consul | 服务发现 + 服务网格（mTLS、流量授权） |
| 应用 | Nomad | 工作负载编排 |

在零信任（Zero Trust）的网络模型里，传统的"网络边界 = 信任边界"假设被彻底抛弃。每一次跨服务调用，无论是同一个 VPC 内还是跨云的，都必须经过 **强身份认证 + 最小权限授权 + 完整审计** 这三道闸门。Vault 正是这三道闸门背后的发动机：

- 它为 Consul 服务网格签发短生命周期的 mTLS 证书
- 它为 Nomad / Kubernetes 中的每个工作负载在运行时动态签发数据库账号、云资源凭据
- 它通过审计设备（Audit Devices）把 **每一次** 机密访问的请求与响应都不可抵赖地记录下来

值得特别强调的是，**Vault 在 Kubernetes 生态中的集成姿态也已经发生范式转移**：从早期需要在每个 Pod 里塞一个 Vault Agent Sidecar 的"侵入式"模式，演进到了通过 **Vault Secrets Operator (VSO)** 以原生 CRD 的方式声明式同步机密——这部分我们会在第 7 章展开。

## 3. 彻底消除"第零号机密"的核心安全哲学

现代 Vault 的安全哲学可以浓缩为一句话：

> **任何长期存在的静态凭据都是漏洞，区别只在于何时被利用。**

这句话推出了三条核心设计原则：

1. **机密都应该是动态生成的（Dynamic Secrets）**：与其存储一个数据库密码，不如让 Vault 在应用需要时实时为它创建一个仅存活 5 分钟的临时数据库账号。
2. **机密都应该绑定租约（Lease）**：每一份动态机密都附带一个 Lease ID 和 TTL，Vault 在租约到期或被显式吊销时，会主动调用对应后端去销毁这份机密。
3. **身份不应该靠"知道一个秘密"来证明**：传统认证靠"我知道密码"；现代认证靠"我能向可信第三方证明我是谁"——基于 JWT 签名、TLS 客户端证书、云平台元数据服务等。

这就是为什么 WIF（用 Vault 签发的 JWT 去换 AWS/Azure/GCP 临时凭据）会成为现代 Vault 的明星特性：它把"Vault 自己持有云厂商的密码"这个最后的静态凭据死角也消灭了。

## 4. 部署初体验：官方安全认证镜像与防投毒机制

当你准备在生产环境跑 Vault 时，第一个安全决策就是：**镜像从哪里拉？**

Docker Hub 上历史上同时存在过 `vault`、`hashicorp/vault`、各种社区维护的镜像，命名混乱给软件供应链攻击留下了可乘之机。HashiCorp 现在的官方立场非常明确：

- **唯一合法来源**：`hashicorp/vault`（带 Verified Publisher 蓝色徽章）
- **拉取方式**：`docker pull hashicorp/vault:<具体版本号>`，**不要使用 `latest`**
- **完整性校验**：HashiCorp 在 [releases.hashicorp.com](https://releases.hashicorp.com/vault/) 同步发布每个版本的 SHA256 校验和及 GPG 签名，建议在生产部署流水线中作为强制校验步骤

这种"显式版本 + 校验和 + 可信发布者"的三重保护，是应对 SolarWinds 式供应链攻击的工业界共识。我们会在动手实验里实际操作一遍这个流程。

## 5. 启动标准 Vault 服务与多节点集群拓扑初探

到目前为止你接触的 Vault 都是 Dev 模式启动的——内存存储、自动解封、Root Token 是 `root`。Dev 模式仅用于学习，**绝不可用于任何生产环境**。

一个最小可用的生产配置由四个 HCL 块组成：

```hcl
# 1. 监听器：定义 API 端口与 TLS（生产中必须开启 TLS）
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = false
  tls_cert_file = "/etc/vault/tls/server.crt"
  tls_key_file  = "/etc/vault/tls/server.key"
}

# 2. 存储后端：现代标准是 Integrated Storage（内置 Raft）
storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

# 3. 集群通信端口
api_addr     = "https://vault-1.example.com:8200"
cluster_addr = "https://vault-1.example.com:8201"

# 4. UI（可选）
ui = true
```

为什么是 Raft？回顾一下原[《Essential Vault》](https://lonegunmanb.github.io/essential-vault/2.%E5%9F%BA%E6%9C%AC%E6%A6%82%E5%BF%B5/13.%E5%AD%98%E5%82%A8.html)介绍的存储后端：Consul、Etcd、各种数据库……都是 **外置** 存储，部署运维复杂度高、版本兼容矩阵庞大。**Integrated Storage** 是 Vault 自己内置的、基于 Raft 一致性协议的嵌入式存储，从 Vault 1.4 开始 GA，现在已经成为官方钦定的事实标准。

生产集群的典型拓扑：

- **奇数个节点**：3 节点（容忍 1 节点失效）或 5 节点（容忍 2 节点失效）
- **一主多从**：Raft 协议保证任一时刻只有一个 Leader 处理写请求，其余 Follower 转发写请求并同步状态
- **Autopilot（自动驾驶仪）**：开源版从 1.7 开始内置，自动管理新节点的稳定期、识别并清理已死亡的节点，避免人工 raft remove-peer 的高风险操作
- **Auto-Unseal**：生产中通常用 AWS KMS / Azure Key Vault / GCP KMS 等云端 KMS 自动解封，避免重启时人工输入 Shamir 密钥分片

## 6. 挂载点模型与请求路由

在看 Vault 的内部架构图之前，先理解一个贯穿全书的基础概念——**挂载点（Mount）**。

Vault 本身并不直接存储机密或验证身份。它把这些能力拆分成一个个独立的**插件**（Secrets Engine 和 Auth Method），每个插件通过一个 **路径前缀** 挂载到 Vault Core 内部的路由表上。你可以把它想象成一个文件系统，每个引擎就是一块"分区"：

```
Vault 路由表
├── secret/           ← KV v2 机密引擎（默认路径）
├── database/         ← Database 动态凭据引擎
├── transit/          ← Transit 加密即服务引擎
├── pki/              ← PKI 证书签发引擎
├── auth/userpass/    ← Userpass 认证方法
├── auth/approle/     ← AppRole 认证方法
├── sys/              ← 系统内置端点（不可卸载）
└── cubbyhole/        ← 每个 Token 私有的临时存储（不可卸载）
```

当你执行 `vault secrets enable -path=my-kv kv-v2` 时，Vault 在路由表中注册 `my-kv/` 这个前缀，并为这个挂载分配一个不可变的 **Accessor**（唯一标识符）。此后所有发往 `my-kv/*` 的请求都会被路由到这个 KV v2 引擎实例。

几个关键性质：

- **同类型可多次挂载**：你可以同时有 `secret/`（开发团队）和 `prod-kv/`（运维团队），它们是两个完全独立的 KV v2 实例，数据互不可见
- **认证方法同理**：`vault auth enable -path=corp-login userpass` 在 `auth/corp-login/` 路径下挂一个 Userpass 实例
- **Policy 基于路径**：Vault 的整个权限体系就建立在这棵路由树上——`path "secret/data/team-a/*"` 指的是"挂载在 `secret/` 的引擎下 `team-a/` 前缀"

下面这张图直观展示了 Vault Core 与各类插件（Secrets Engine / Auth Method）之间通过挂载路径建立的路由关系：

![Vault 与插件的挂载路由关系](/images/what-is-vault/vault-mount-routing.png)

理解这一点之后，下面架构图中的"路由到 Secrets Engine"就不再抽象——它就是查这张路由表，按路径前缀把请求分发到对应的引擎插件。后续学习 Policy（2.6 节）、Identity（2.5 节）、以及 Mount Migration（2.8 节）时，也都会反复回到这个模型。

查看当前系统中所有已挂载的引擎和认证方法：

```bash
vault secrets list    # 机密引擎
vault auth list       # 认证方法
```

---

## 7. 内部架构与加密屏障

有了挂载点和路由表的概念后，现在来看完整的架构。Vault 最关键的设计是 **Barrier（屏障）**——存储后端始终被视为 **不可信** 的，任何写入存储的数据都先经过 Barrier 用 AES-GCM-256 加密。

```
┌──────────────────────────────────────────────────┐
│                  Client (CLI / API)              │
└────────────────────┬─────────────────────────────┘
                     │  HTTPS API
                     ▼
┌──────────────────────────────────────────────────┐
│  Vault Core                                      │
│                                                  │
│  ① Auth Methods ─→ 验证身份，返回 Token          │
│         │                                        │
│         ▼                                        │
│  ② Policy Engine ─→ 按 Token 绑定的 Policy，     │
│         │            用请求路径做 ACL 判定         │
│         ▼                                        │
│  ③ Router（路由表）─→ 按路径前缀分发到引擎        │
│    ┌────┴──────────────┐                         │
│    ▼                   ▼                         │
│  Secrets Engines    Audit Devices                │
│  (KV/DB/PKI/...)    (File/Syslog/Socket)         │
│    │                   │                         │
│    ▼                   ▼                         │
│  ═══════════════ Barrier (AES-GCM-256) ════════  │
│                    │                             │
│           ┌────────▼────────┐                   │
│           │ Storage Backend │                   │
│           │  (Raft / etc.)  │                   │
│           └─────────────────┘                   │
└──────────────────────────────────────────────────┘
```

对照上图理解几个关键点：

1. **请求流转串联了第 6 节的路由表**：每一次 API 请求依次经过 `① 认证 → ② 策略评估（按路径匹配 Policy）→ ③ 路由（按路径前缀查路由表，分发到对应引擎）→ 审计`。任何一步失败都会被审计设备完整记录。
2. **三层密钥结构**：Vault 持久化数据用 **Encryption Key**（在 keyring 里）加密；Encryption Key 用 **Root Key** 加密；Root Key 用 **Unseal Key** 加密。Unseal Key 通过 Shamir 算法切分成 N 份，需要 K 份才能重组（默认 5/3）。
3. **Sealed 与 Unsealed**：Vault 启动时处于 Sealed 状态——它能读到加密后的字节，但解不开。提供足够份数的 Unseal Key 重组出 Root Key 后，Vault 才能解密 keyring 进入 Unsealed 状态。**Sealed 状态下，路由表、引擎、Policy 全部不可用**——唯一能响应的只有 `sys/seal-status` 和解封相关的端点。
4. **Auto-Unseal** 不是绕过这个机制，而是把"持有 Unseal Key 的人"换成了一个可信的 KMS 服务——Root Key 由 KMS 帮你保管和解密，Vault 启动后直接向 KMS 请求解封。这同时引入了"Recovery Key"概念，用于 root token 重建等少数仍需多人授权的特殊操作。
5. **审计的不可抵赖性**：审计日志在写入前会用 HMAC 对敏感字段哈希处理，既保证了审计完整性，又不会把明文密码二次落盘。

---

## 总结

本章的目的是建立心智模型，而不是动手操作。请记住三个核心概念：

- **Vault 是"身份与机密的协商中枢"**，不仅仅是加密存储
- **生产 Vault = Integrated Storage (Raft) + Auto-Unseal + Autopilot**
- **Barrier、Seal/Unseal、Lease 是理解 Vault 一切行为的三块基石**

下面进入实验环节，亲手部署一个生产风格的 Vault 节点，并通过观察存储目录里的二进制文件来直观理解 Barrier 的加密效果。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/what-is-vault" title="实验：部署生产风格的 Vault（Raft + Shamir 解封）" />
