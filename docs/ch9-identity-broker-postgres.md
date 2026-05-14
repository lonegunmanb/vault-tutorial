---
order: 97
title: 9.6 Vault 作为身份代理（Identity Broker）：把 AWS IAM 与 K8s ServiceAccount 联邦到 PostgreSQL 动态账号
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.6 Vault 作为身份代理（Identity Broker）：把 AWS IAM 与 K8s ServiceAccount 联邦到 PostgreSQL 动态账号

> **核心结论**：Vault 最容易被低估的能力，并不是"集中保管口令"，而是 **作为身份代理（identity broker）**——它先验证调用方在某个外部身份域（AWS / Kubernetes / OIDC / TLS 客户端证书等）里**到底是谁**，再以该身份为锚点、把对**另一个目标系统**（在本节里是 PostgreSQL）的访问 **现场签发**为一份短生命周期、随用随建、用完即销的动态凭据。本节用 PostgreSQL 作为统一的"目标域"，演示**两种不同来源的工作负载身份**如何走完同一条 brokering 流水线：（1）一台拿着 AWS IAM 凭据的"外部主机"调用方；（2）一只跑在 Kubernetes 集群里、靠 ServiceAccount 自证身份的 Pod。学员将在 Killercoda 提供的单节点 Kubernetes 环境里把这条 zero-trust 流水线**完整跑两遍**，亲眼看到"换认证方、不换数据库授权配置"是 Vault identity brokering 范式的精髓。本节面向已经分别学过第 4.3、4.4、3.14 章基础内容的学员，但不要求信息安全方面的专业背景。

参考：
- 主参考：[Vault as an identity broker for zero trust security — HashiCorp Validated Patterns](https://developer.hashicorp.com/validated-patterns/vault/vault-trusted-identity-brokering)
- [Database secrets engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/databases)
- [AWS auth method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/aws)
- [Kubernetes auth method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- 已学衔接：[3.14 PostgreSQL 数据库机密引擎](/ch3-postgres)、[4.3 AWS 认证方法](/ch4-aws)、[4.4 Kubernetes 认证方法](/ch4-k8s)、[2.3 租约与生命周期](/ch2-lease)

---

## 1. 为什么"把 Vault 当口令保险柜"是把 Vault 用浅了

很多团队第一次接触 Vault 时，都把它**当作一台加密过的 KV 存储**：把数据库口令、第三方 API key 写进去，应用启动时取一次就走。这种用法解决了"口令明文写在配置文件里"这一显性痛点，但**没有改变安全模型的本质**——口令依然是长生命周期、依然在应用进程内存里以明文驻留、依然要靠人去手工轮转。一旦被偷走、被 dump、被泄到日志里，攻击者拿到的依然是"打开数据库前门的钥匙本身"。

Vault 的**真正定位**应当是**身份代理（identity broker）**——它的核心动作不是"把口令交给你"，而是"先验证你在**某个外部身份域**里到底是谁，然后据此**现场为你在另一个目标系统里签发一份临时通行证**"。这种范式在官方文档里被精准概括为："**verifying identities from one platform and brokering access to another**"。它把传统的"持有静态机密 = 拥有访问权"翻转为"**持续验证动态身份 = 临时获得短期访问**"——这正是 NIST SP 800-207 所定义的零信任架构核心原则。

> **必须给初学者澄清的一点**：本节讨论的**所有**机制——动态凭据、短租约、auth method、policy——前面章节都分别介绍过。本节不是引入新组件，而是**把它们组合成一条端到端的流水线**，让学员看到"组合之后呈现出的整体行为"远不是"各部件加起来"那么简单。这条流水线的特征是 *identity in, dynamic credential out*——**进去的是身份，出来的是凭据**——这是 Vault 区别于任何"加密 KV 存储"的根本。

---

## 2. Identity brokering 的三阶段事务模型

官方文档把一次完整的 brokering 事务拆成**三个不可省略的阶段**——理解这三阶段的边界，是理解后面动手实验"为什么是这样配置"的前提。

### 2.1 Phase 1 — 身份验证与 token 签发（Authentication）

调用方（一台 EC2 实例、一只 K8s Pod、一个 OIDC 用户……）首先用**它在外部身份域里的原生凭据**向 Vault 的某个 auth method 发起登录。Vault 不会盲信调用方自己说的话——它会**主动向外部身份提供商发起 out-of-band 调用**做最终判定：例如调用 Kubernetes API 的 TokenReview 端点验证 ServiceAccount JWT、调用 AWS STS 的 GetCallerIdentity 验签 IAM 签名请求。验证通过后，Vault 才**为该外部身份签发一枚短生命周期 Vault token**，并把外部身份的关键属性（ServiceAccount 名、IAM ARN 等）作为 metadata 永久绑定在这枚 token 上。**这一阶段不授权任何业务资源访问，只回答"你是谁"**。

### 2.2 Phase 2 — 身份到权限的映射（Authorization）

调用方拿着 Phase 1 的 Vault token 发起业务请求（例如"请给我一份 PostgreSQL 凭据"）。Vault 这时去做的是**纯内部的策略判定**——把 token 上挂着的 ACL policy 列表（HCL 写的 deny-by-default 路径规则）拿出来，对当前请求路径做 capability 匹配。**这一阶段决定"你能不能向后端发请求"**，但还没有任何业务系统被打扰。

### 2.3 Phase 3 — 动态凭据生成与外部权限映射（Issuance）

ACL 通过后，Vault 才**真正去敲 PostgreSQL 的门**——它用 `database/config/<name>` 里配置的 admin 凭据连进 PostgreSQL，按 `database/roles/<role>` 的 SQL 模板**临时 CREATE ROLE / GRANT** 一份带 TTL 的短期账号，把账号名和密码原路返还给调用方。账号本身的权限边界（SELECT 哪些表、INSERT 哪些表）**完全由 SQL 模板而非 Vault ACL policy 决定**——这是初学者最容易混淆的一处："Vault policy 决定能不能拿到凭据，PostgreSQL 内的 GRANT 决定凭据本身能干什么"。这份临时账号绑定了 lease（租约），TTL 到期后 Vault 会**主动**回到 PostgreSQL 执行 `revocation_statements` 把它 DROP 掉。

把三阶段画成时序图大致是这样：

```text
工作负载 ──(原生身份凭据)──▶ Vault auth/<method>/login
                              │
                              │ ① 外呼 IdP 验身份（TokenReview / STS）
                              ▼
                            外部 IdP
                              │
                              │ 返回 "确实是这个身份"
                              ▼
工作负载 ◀──(短期 Vault token + metadata)── Vault
       │
       │ 持 token 请求 database/creds/<role>
       ▼
        Vault                                      PostgreSQL
         │── ② ACL policy 检查（纯 Vault 内部）──┐
         │                                         │
         │── ③ 用 admin 连入 PG，按模板 ──────────▶│ CREATE ROLE
         │     CREATE ROLE 临时账号                │
         │◀── 返回 username/password ────────────┤
         │                                         │
工作负载 ◀──── { username, password, lease } ────┤
       │                                          │
       │ 用临时账号直连 PG 跑业务 SQL ───────────▶│ SELECT ... 业务数据
       │                                          │
       │ Lease TTL 到期                          │
         │── ④ Vault 主动 DROP 临时账号 ──────────▶│ DROP ROLE
```

---

## 3. 为什么 PostgreSQL 是讲解 brokering 的最好"目标域"

在挑选"目标域"演示 brokering 时，PostgreSQL 是教学价值最高的选择，原因有三：

1. **它是真实生产里最普遍的有状态服务**——绝大多数业务系统的"最后一公里"都要落到一个关系型数据库。把 Vault 与 PostgreSQL 串起来，学员立刻能看到课堂内容与生产场景的直接对应。
2. **它的权限模型是"账号 + GRANT"**——而 Vault 的动态凭据机制天然就以"创建账号 + 套 GRANT 模板 + 到期 DROP"为基本单元。两者是**同构的**，无需任何额外的中间层。
3. **它能让"换认证方、不换目标域配置"这条核心证据被亲眼看到**——本节的两个动手步骤共用**同一个** `database/config/postgres-broker` 与**同一条** `database/roles/readonly` 模板；区别**只在 Phase 1 的认证方法**（一个 `aws`、一个 `kubernetes`）。这就是 Vault identity brokering 的核心抽象——**身份与凭据彻底解耦**，学员看完两个实验就能体会到。

---

## 4. 第一条流水线：AWS IAM → Vault → PostgreSQL

第一个场景对应官方文档明确点名的两个 true brokering 范例之一：**AWS to PostgreSQL**。原文如此描述：「An EC2 instance authenticates to Vault using its IAM role. Vault verifies its identity and creates a short-lived PostgreSQL user and password.」实验里用 LocalStack 在本机模拟 AWS 的 IAM 与 STS 服务，让整条链路**完全离线、完全免费、不动用任何真实云账号**就能跑通，但 API 流量、签名格式、错误响应**与真实 AWS 一致**，因此学员复现的是货真价实的 AWS auth 流程。

完整流水线如下：

1. 在 LocalStack 上创建一个 IAM user（模拟"业务主机的 IAM 身份"），抓出它的 access key / secret key；
2. 在 Vault 上启用 `aws` auth method、把 `sts_endpoint` / `iam_endpoint` 都指向 LocalStack（这是社区版完全可用的官方支持参数）；
3. 在 Vault 上创建一条 `auth/aws/role/app-aws` role，**用 `bound_iam_principal_arn` 把 Phase 1 的可登录身份精确绑定到那个 IAM user 的 ARN**，并把 token 上挂的 ACL policy 设为只允许访问 `database/creds/readonly` 这一条路径；
4. 在 Vault 上启用 `database` engine、用 `database/config/postgres-broker` 配置一对**仅用于 Vault 自身**的 admin 凭据（实验里是 `vaultadmin`），并 `rotate-root` 把这对凭据从 PG 端切换为 Vault 内部独占；
5. 在 Vault 上创建 `database/roles/readonly`：模板是"`CREATE ROLE {{name}} ... GRANT SELECT ON demo.* TO {{name}}` + 到期 `DROP ROLE`"，TTL 默认 2 分钟；
6. 用 IAM user 的 access key 走 `vault login -method=aws role=app-aws`——CLI 内置 iam 登录支持，会自动用本地凭据签 `sts:GetCallerIdentity` 请求并把签名提交给 Vault，Vault 转发给 LocalStack STS 验签后才签出 Vault token；
7. 拿这枚 Vault token 调 `database/creds/readonly`，得到 `username=v-aws-readonly-xxxx` / `password=…` / `lease_id`；
8. 用这对凭据 `psql` 直连 PostgreSQL，执行 `SELECT * FROM demo.kv` 拿到业务数据；
9. `vault lease revoke <lease_id>`，回到 PG 端 `\du` 验证临时账号已被 Vault 主动 DROP 干净。

这条流水线里**最值得反复观察**的不是任何一行命令的输出，而是"Phase 1、2、3 的边界永远是清晰的"——审计日志里能精确看到三类不同的事件：`aws/login` 成功、`database/creds/readonly` 的 ACL 检查通过、`PostgreSQL CREATE ROLE` 的下游执行；任何一条出问题，都能立刻定位到对应的 Phase。

---

## 5. 第二条流水线：Kubernetes ServiceAccount → Vault → PostgreSQL

第二个场景把 Phase 1 的认证方法换成 Kubernetes，但 Phase 2 的 ACL policy（除了 role 名字不同）与 Phase 3 的 PostgreSQL 配置**一行都不改**——这是本节最有冲击力的设计。完整流水线如下：

1. 在 Killercoda 预置的单节点 K8s 集群里，创建一个 namespace `demo`、一个 ServiceAccount `app-k8s`；
2. 在 Vault 上启用 `kubernetes` auth method，配置 reviewer JWT、API server 地址、CA 证书（前面 4.4 章已经讲过，这里不再重复机制）；
3. 在 Vault 上创建一条 `auth/kubernetes/role/app-k8s` role，**用 `bound_service_account_names=app-k8s, bound_service_account_namespaces=demo` 把 Phase 1 的可登录身份精确绑定到那个 ServiceAccount**，token 上挂的 ACL policy **复用**第一场景的 `db-readonly` policy；
4. 在集群里 `kubectl run` 一个 Pod，把 `serviceAccountName: app-k8s` 显式声明、并把 vault CLI 注入 Pod；
5. 在 Pod 内 `kubectl create token app-k8s --audience=...` 取得短期 JWT，用 `vault write auth/kubernetes/login role=app-k8s jwt=$JWT` 换取 Vault token——Vault 内部走 TokenReview 路径回调集群 API server 完成验证；
6. 拿到 Vault token 后，**调的是与第一场景完全相同的** `database/creds/readonly`，**得到的是与第一场景同构的** `v-kubernetes-readonly-xxxx` 账号，**连进的是同一个** PostgreSQL 实例的同一张表。

教学上的关键证据有两条：

- **`database/config/postgres-broker` 与 `database/roles/readonly` 在两个场景之间一个字符没改**——这说明 Vault 已经把"身份"与"凭据"彻底解耦：上游可以是任何 auth method，下游的凭据生成逻辑只需要写一遍。
- **PostgreSQL 端 `\du` 看到的临时账号前缀，会在两个场景里分别带上 auth method 名（`v-aws-readonly-...` 与 `v-kubernetes-readonly-...`）**——这是 Vault 自动写入的 metadata，便于审计时反向追溯"这个临时账号是从哪条认证路径派生出来的"。

---

## 6. 反 brokering 的两个常见反模式（必须警惕）

教完正向范式之后，必须把官方明确点名的**反模式**拿出来对照——否则学员会把任何"用 Vault + 动态凭据"都误解为 brokering。

### 6.1 反模式一：CI/CD pipeline 拉机密注入应用环境变量

CI/CD 流水线用**自己的身份**登录 Vault，拉一份机密（动态或静态都不算 brokering！），把它通过环境变量、Secret 资源或配置文件**注入应用部署**。这种做法常被宣传为"用了 Vault 就是 zero trust"，**但它根本不是 brokering**——因为：

- 用 Vault 做认证的是 CI/CD 流水线，**不是应用本身的运行时身份**；
- 注入到应用里的还是一段静态字符串，应用进程本身**没有**与 Vault 建立任何身份关系；
- 凭据生命周期与 CI 任务相关，**与应用 Pod 的实际生命周期解耦**——Pod 重启时凭据可能已经过期、应用却没机会刷新。

这种做法在工程上比"硬编码到镜像里"略有改善，但**没有改变安全模型**——它只是把"静态机密的存放位置"从源代码里挪到了 Vault 里，应用拿到的依然是一段长期持有的字符串。

### 6.2 反模式二：长生命周期 AppRole

把一对 AppRole `RoleID` / `SecretID` 长期颁发给一个应用、应用启动时持这对凭据登录 Vault——这看起来"应用自己带身份登录"，**但它依然不是 brokering**——因为：

- AppRole 的 `RoleID` / `SecretID` **是 Vault 自己颁发的、应用之外的另一对静态凭据**，并不是应用在某个外部身份域里的"原生身份"；
- 这对凭据需要被分发、保管、轮转——本质上**只是把"一个静态机密"换成了"另一个静态机密"**；
- 它退化成了所谓的 "secret zero" 问题——应用要安全地拿到 RoleID/SecretID，往往又得依赖另一套机制（环境变量、配置中心、SCM 模板……），把"机密蔓生"问题在另一个层面再演一遍。

> **必须给初学者澄清的一点**：AppRole 本身**并不是被禁用的功能**——在没有平台原生身份可用的场景里（例如裸金属服务器跑一个无 IAM 集成的进程），AppRole 仍然是合理的"次优解"，但必须配套一套受信任的 orchestrator 来负责把 SecretID 安全分发出去。教程下方的实验只演示**正向范式**——AWS IAM 与 K8s ServiceAccount 这两类**真正的平台原生身份**。

---

## 7. Brokering 模式与 NIST 零信任架构的对应关系

把 brokering 与 NIST SP 800-207 定义的零信任架构（Zero Trust Architecture, ZTA）核心原则做一一对照，能让学员理解"为什么这套范式不是某家厂商的 marketing slogan，而是国家级标准的直接落地"：

| NIST 原则 | brokering 范式如何落实 |
| --- | --- |
| **No implicit trust**（不基于网络位置授予隐性信任） | 每次请求 Vault 都要**重新走完 Phase 1 验证**，无论调用方在内网还是公网 |
| **Per-session access**（按会话授权） | 动态凭据自带 lease/TTL，**每个临时账号都是为单次会话单独生成** |
| **Dynamic policy enforcement**（动态策略） | Vault role 的 `bound_*` 字段把外部身份属性纳入策略判定，policy 还可绑定 metadata |
| **Continuous authentication and authorization**（持续验证与授权） | token 与租约都要主动续期，过期就重新走 Phase 1，**不存在"一次登录、永久有权限"** |

---

## 8. 本节小结

把上面 7 节的概念拆出来的要点浓缩为一份**可立即对照执行的清单**：

1. **Vault 的核心定位是 identity broker，不是 KV 保险柜**——把 Vault 用浅了的最常见症状是"只用它的 KV 引擎"；
2. **brokering 是三阶段事务**——Phase 1 验证身份（Vault 外呼 IdP）、Phase 2 内部 ACL 判定、Phase 3 现场签发外部凭据；
3. **同一条 Phase 3 配置可以服务于多种 Phase 1 认证方法**——这是 brokering 范式的真正抽象，本节末尾的实验会让学员亲眼看到；
4. **Phase 3 的权限边界由目标系统的原生 GRANT 决定，不由 Vault ACL 决定**——这是初学者最易混的概念边界；
5. **CI/CD 拉机密注入环境变量、长生命周期 AppRole 都不是 brokering**——前者认证主体错（流水线而非应用）、后者依然在分发静态机密；
6. **brokering 范式是 NIST SP 800-207 的直接落地**——四条核心原则一一对应；
7. **优先选用平台原生身份**（K8s ServiceAccount、AWS IAM、Azure AD……），AppRole / TLS 客户端证书只在没有原生身份可用时作为次选。

掌握以上七条之后，下一节的动手实验会让学员**亲自把同一份 PostgreSQL 动态凭据机制接到两种完全不同的认证方法上**——AWS IAM 与 K8s ServiceAccount——并在终端里直接观察"换上游、不换下游"的真实效果。

---

## 9. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 提供的**单节点 Kubernetes 主机**上**完整跑两遍** identity brokering 流水线，目标系统都是同一个 PostgreSQL，只在 Phase 1 的认证方法上有所区别——

1. **第一步（AWS IAM → PostgreSQL）**：用 LocalStack 模拟 AWS 的 IAM/STS 服务，创建一个 IAM user 作为"外部主机身份"，启用 Vault `aws` auth、用 `sts_endpoint` 指向 LocalStack；启用 `database` engine 接到本地 PostgreSQL 上；用 IAM user 凭据登录 Vault，拿 token 调 `database/creds/readonly`，得到临时账号后 `psql` 直连 PG 跑业务 SQL；revoke lease 后回 PG 验证账号已被 Vault 主动 DROP 干净。
2. **第二步（K8s ServiceAccount → PostgreSQL）**：在同一份 PostgreSQL 配置 / 同一条 `database/roles/readonly` 模板上，启用 Vault `kubernetes` auth、绑定一个 `demo/app-k8s` ServiceAccount；`kubectl run` 一个 Pod 用该 SA 启动，进 Pod 后用 `kubectl create token` 签 JWT、`vault write auth/kubernetes/login` 换 Vault token、再调**同一条** `database/creds/readonly`，得到同构的临时账号；亲眼看到"换上游、不换下游"是 Vault brokering 范式的真正抽象。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-identity-broker-postgres" title="实验：把 AWS IAM 与 K8s ServiceAccount 联邦到同一份 PostgreSQL 动态凭据" />
