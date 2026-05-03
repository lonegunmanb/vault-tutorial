---
order: 41
title: 4.2 AppRole 认证：机器登录 Vault 的"用户名/密码"
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.2 AppRole 认证：机器登录 Vault 的"用户名/密码"

> **核心结论**：AppRole 是 Vault 专门**给机器/应用**用的认证方法。它把
> "应用如何向 Vault 证明身份"拆成两半——**RoleID**（半公开的"用户名"，
> 用来声明"我属于哪个 role"）和 **SecretID**（保密的"密码"，必须始终
> 保密）。它**不是**云平台 / Kubernetes / OIDC 那种"由可信第三方背书"
> 的认证方式，而是一种**"可信中介（trusted broker）"** 模式：信任的根
> 不在第三方，而落在那个负责把两半凭据分别经办、分发给最终消费者的中
> 间系统（比如 Jenkins worker）——而**这个中间系统本身也不应同时握有
> 完整的两半凭据**。本章先讲清 AppRole 的概念与字段，再讲清楚为什么
> "两份凭据通过两条不同通道交付给最终客户端"是它的使用范式，最后在
> 动手实验里把 Pull 模式 + CIDR 限制 + Response Wrapping + 反模式现场
> 全部跑一遍。

参考：
- [Use AppRole authentication](https://developer.hashicorp.com/vault/docs/auth/approle)
- [Best practices for AppRole authentication](https://developer.hashicorp.com/vault/docs/auth/approle/approle-pattern)
- [AppRole API](https://developer.hashicorp.com/vault/api-docs/auth/approle)

---

## 1. AppRole 在 Vault 认证体系里的位置

回到 [4.1 章](/ch4-auth-basic) 那张分类表：Vault 的内置认证方法按"凭
据来源"大致分四类——用户/口令、平台/工作负载身份（AWS / GCP /
Kubernetes / JWT）、联邦 SSO（OIDC / SAML / GitHub）、以及"凭据型 /
自举型"。**AppRole 落在最后一类**——它解决的是"应用程序怎么向 Vault
证明自己"，而不是"人类怎么登录"。

> Vault 的官方原话：_"If another platform method of authentication is
> available via a trusted third-party authenticator, the best practice
> is to use that instead of AppRole."_ 翻译过来就是：**只要有可用的可
> 信第三方认证器（官方举的例子是 AWS、LDAP、GitHub 等），就优先用那
> 个；AppRole 是兜底方案**——留给那些没有可信第三方背书可用的应用一
> 条标准化认证通道。

这里有一个关键区别需要明确：AppRole **不是"可信第三方认证
（trusted third-party）"**，而是一种 **"可信中介（trusted broker）"**
模式。

打个比方就清楚了：

- **可信第三方认证**（AWS / Kubernetes / OIDC 这类）：好比你去办事，
  出示**身份证**——发证的是公安部门，办事窗口直接打电话回公安核实。
  Vault 信的是"公安部门"这个**外部权威**，跟你怎么把身份证带过来无关。
- **可信中介（AppRole）**：Vault 之外**没有任何权威可问**——RoleID 和
  SecretID 默认由 Vault 现场生成（也允许配置为自定义值），而**谁手里
  同时握着这两个字符串，通常就具备登录能力**（如果 role 上还加了
  CIDR 等约束，还必须同时满足这些约束，详见 §4.2 / §5.1）。所以"这次
  登录确实代表那个真正的应用"这件事的可信度，**完全寄托在分发凭据的
  那个中间系统身上**
  （Jenkins worker、调度器、镜像构建管线等）：是它负责把 RoleID 发
  给 A 应用、把 SecretID 发给 A 应用，且**只发给 A**。

换句话说：用 AppRole 的时候，**安全责任落在你（配置者）自己头上**，
没有云厂商或 K8s 帮你背书。这也是为什么后面 §6 要专门讲怎么把两半凭
据"分两条路"送到客户端、§8 要专门列反模式——因为没有第三方兜底，那
个"中介系统"怎么管凭据分发，就成了整套机制能不能站得住的唯一关键。

这套机制围绕一条核心原则成立：**RoleID 与 SecretID 这两半凭据，唯一
能同时出现的位置是最终消费机密的那台终端机器**。中间任何一个系统
（包括中介本身）都不应该同时握有完整的两份凭据；一旦"两半在中途凑
齐"，trusted broker 模式的安全前提就被打破了。

AppRole 模型里有三个角色：**Vault 服务**本身、**broker（中介）**——
那个被严密管控、负责经办认证的系统、以及 **secret consumer（机密最
终消费者）**——真正去 Vault 取机密的应用。教程后面 §6 的 Jenkins 工
作流就是这三个角色的一个典型示例。

> 这套设计还有**两条根本原则**贯穿全文，后面 §8 的反模式判别会反复
> 用到：
>
> 1. **Blast-radius of an identity**——每个认证身份只能访问它真正
>    需要的那部分机密；机密不应在 Vault 与最终消费者之间被
>    任何中间方代为读取。
> 2. **Duration of authentication**——一个 token 的存活时间应当只
>    覆盖它真正需要访问机密的那段时间。

---

## 2. 概念字典：RoleID、SecretID、AppRole role

本节先把这几个名词明确下来，避免后面把 "role"、"role-id"、"approle"
混着用。

| 术语 | 定义 |
| :--- | :--- |
| **Authentication / AuthN** | 认证 = 确认身份的过程 |
| **Authorization / AuthZ** | 鉴权 = 确认某身份能访问什么、到什么级别的过程 |
| **RoleID** | role 的"半秘密"标识符——把它类比成认证对子里的**用户名**部分 |
| **SecretID** | role 的秘密标识符——类比成认证对子里的**密码**部分 |
| **AppRole role** | Vault 里配置的 role 对象——里面装着鉴权和使用参数 |

> **一个最常踩的坑：把 "AppRole" 和 "role" 当一回事**。
>
> - **AppRole**：Vault 内置的**一种认证方法**（auth method 类型名）
> - **role**：是 AppRole 这个认证方法**下面**配置出来的具体策略实例
>   （`auth/approle/role/<role-name>`）；一个 AppRole 挂载下可以配
>   置多个 role
>
> 后面文档里说 "AppRole role" 时，特指"AppRole 这个挂载下的某个具体
> role 对象"。

---

## 3. RoleID：能公开的"用户名"

RoleID 看似矛盾、但其实是个非常关键的设计：**RoleID 不是机密**——
它是一个静态 UUID，唯一标识某个 role 配置；通常是一个应用对应一个
role，所以也就一个 RoleID。它可以被嵌入机器镜像、容器镜像、环境变
量里。

> 典型的分发方式：用 [Packer](https://developer.hashicorp.com/packer/tutorials/) 构建镜像时把
> RoleID 直接写成环境变量；用 [Terraform](https://developer.hashicorp.com/terraform/tutorials/)
> 配置机器时把 RoleID 注入进去。

但 "不是机密" ≠ "随便放" 。在 trusted broker 工作流里，RoleID 一般
**直接由部署系统嵌入**到目标客户端；要不就是从 Vault 现读，但这条路
径需要一个最小权限策略：

```hcl
# 给一个最小权限：只能读名为 jenkins 的 AppRole 的 role-id
path "auth/approle/role/jenkins/role-id" {
   capabilities = [ "read" ]
}
```

回到 API 层：登录端点 `auth/approle/login` 把 `role_id` 当成**始终
必须**的参数。RoleID 默认就是 Vault 自动生成的 UUID，但**也可以被设
成自定义值**——比如直接设为客户端的域名，让请求里"声明的 role"和
"客户端 introspection 出来的身份"自然对齐。

> 自定义 RoleID 一般通过 AppRole 的 `role-id` 子端点写入；具体 CLI /
> API 形式见 [AppRole API 文档](https://developer.hashicorp.com/vault/api-docs/auth/approle)。
> 这条路径主要用于"已有部署体系本身已经能给每台机器分配一个稳定字符
> 串身份"的场景，把它复用为 RoleID 即可。

---

## 4. SecretID：必须保密的"密码"

SecretID 是登录时**默认必须**的另一半凭据，通过 `secret_id` 参数提
交。它的设计意图就是"始终保密"。SecretID 既可以由 role 自己生成（一
段 128 位的纯随机 UUID，这叫 **Pull 模式**），也可以由客户端设置一个
"自定义 SecretID"（这叫 **Push 模式**）。SecretID 跟 token 一样，有
**使用次数上限、TTL、过期时间**这些属性。

**SecretID 是密码！**
**SecretID 是密码！**
**SecretID 是密码！**

### 4.1 Pull 模式 vs Push 模式

| 模式 | 谁来生成 SecretID | 典型命令 |
| :--- | :--- | :--- |
| **Pull**（推荐） | 调用 Vault 的 `auth/approle/role/<role>/secret-id` 端点，由 role 现场生成一个 128 位 UUID | `vault write -f auth/approle/role/my-role/secret-id` |
| **Push**（兼容老 App-ID） | 客户端自己提供一个 SecretID 字符串，通过 AppRole API 写入 | 见 AppRole API 文档 |

为什么大多数情况下要选 Pull 模式？关键在于：**Push 模式要求某个其
它系统提前知道完整的客户端凭据集（RoleID 与 SecretID）才能创建
entry**——即便后续走两条不同路径分发，"凑齐两半"这件事本身已经发生
过一次。而 Pull 模式下，虽然 RoleID 仍要被知道并分发出去，**SecretID
可以借助 [Response Wrapping](/ch2-response-wrapping) 对除最终客户端外
的所有方都保密**。

> Push 模式仍然存在，主要是给"从已废弃的 App-ID 工作流迁移过来的应用"
> 留兼容层；新设计的应用大多数情况下应优先 Pull。

### 4.2 SecretID 不是限制登录的唯一硬约束

`role_id` 是登录端点的硬性必填参数；`role_id` 指向的那个 AppRole 上
可以配各种约束，决定**还需要带哪些其它凭据/满足哪些条件**才能拿到
token。`bind_secret_id` 这个约束要求登录请求里必须带 `secret_id`——这
是默认行为；但**如果把 `bind_secret_id` 关掉**（设为 `false`），加上
其它约束（比如 `secret_id_bound_cidrs`），就可以让"只知道 RoleID、来
自指定 IP 段的客户端" 直接拿 token，不需要 SecretID。

> 实验 Step 3 会用 `secret_id_bound_cidrs` 演示一次 IP 段约束在 Vault
> 端就直接把不合规请求拒掉的现场。

---

## 5. SecretID 的两道安全装置

SecretID 是机密——既然要分发给最终消费者，分发过程本身就是攻击面。
针对 SecretID 分发的安全，有**两个**配套的增强机制可用：**Binding
CIDRs** 和 **AppRole response wrapping**。

### 5.1 Binding CIDRs：在 Vault 端把不合法 IP 拦掉

定义 AppRole 时可以用 `secret_id_bound_cidrs` 参数指定**允许执行登录
操作的 IP 段**；还可以用 `token_bound_cidrs` 进一步限制**这枚 token
本身能在哪些 IP 段被使用**。

一个典型的范例命令：

```shell-session
$ vault write auth/approle/role/jenkins \
      secret_id_bound_cidrs="0.0.0.0/0","127.0.0.1/32" \
      secret_id_ttl=60m \
      secret_id_num_uses=5 \
      enable_local_secret_ids=false \
      token_bound_cidrs="0.0.0.0/0","127.0.0.1/32" \
      token_num_uses=10 \
      token_ttl=1h \
      token_max_ttl=3h \
      token_type=default \
      period="" \
      policies="default","test"
```

> CIDR 列表本身有规模限制：**没有硬上限，但实际限制因素有两个**——
> Vault 比对 IP 与列表所需的时间、以及 HTTP 请求的最大体积。CIDR 段
> 越多，这两项压力都会随之上升。

### 5.2 Response Wrapping：把 SecretID 装进一次性信封

为了**保证 SecretID 的机密性、完整性、不可否认性**，可以在生成
SecretID 时加 `-wrap-ttl` 标志。Vault 不会把 SecretID 明文返回，而
是把它放进一个新生成的 token 的 Cubbyhole，这枚 token 的使用次数
被硬编码为 **1 次**。当应用尝试读取 SecretID 时，**可以保证只有这个
应用能读取到**——任何中途偷看的行为都会让合法应用收到"已被使用"的
错误，从而立刻识破。

实际命令：

```shell-session
$ vault write -wrap-ttl=60s -force auth/approle/role/jenkins/secret-id

Key                              Value
---                              -----
wrapping_token:                  s.yzbznr9NlZNzsgEtz3SI56pX
wrapping_accessor:               Smi4CO0Sdhn8FJvL8XvOT30y
wrapping_token_ttl:              1m
wrapping_token_creation_time:    2021-06-07 20:02:01.019838 -0700 PDT
wrapping_token_creation_path:    auth/approle/role/jenkins/secret-id
```

最后一道防线是**审计日志**：监控对 SecretID 读取的尝试。如果应用拿
着这枚 wrapping token 去 unwrap 时收到"use-limit"错误，就说明**有别
人先读过它**——审计日志里能直接看到那一次抢先 unwrap 的来源。

> Wrapping 只是**装信封**——SecretID 自身的 TTL 和使用次数仍然由 role
> 配置决定。它可以与 `secret_id_num_uses=1`、`secret_id_bound_cidrs`
> 等约束**叠加使用**：wrapping 防的是运送途中的偷看，num_uses / CIDR
> 限的是 SecretID 本身能被怎么用。

---

## 6. trusted broker 工作流：把两半凭据分两条路送

讨论清楚字段层面后，到这一节才是 AppRole 真正的使用范式：**严禁让
任何一个系统（除最终客户端外）同时握有 RoleID 和 SecretID**。

> 推荐的实现方式是：**把这两个值通过两条不同的通道分发**。给每个可信
> 的编排器（orchestrator）发的 token 都被范围严格限制——每个编排器
> 要么只能拿 RoleID、要么只能拿 SecretID，**永远不可两个都能拿**。

### 6.1 Jenkins CI/CD 范例工作流（10 步）

下面用一段典型的 Jenkins 工作流来落地这条原则——master + worker +
短生命周期 runner 的拓扑刚好把"两条通道"分发演示得很完整：

![AppRole trusted broker 工作流：餐厅取餐窗口比喻](/images/ch4-app-role/trusted-broker-workflow.png)

| # | 动作 |
| :--- | :--- |
| 1 | Jenkins worker 自己向 Vault 认证 |
| 2 | Vault 给 worker 返回一枚 token |
| 3 | worker 用这枚 token 去取 wrapped SecretID（注意：是 wrapped，不是裸的） |
| 4 | Vault 返回一枚 wrapping token |
| 5 | worker 启动 runner 容器，把 wrapping token 当变量传进去 |
| 6 | runner 容器在内部 unwrap 这个 token，拿到 SecretID |
| 7 | Vault 返回 SecretID |
| 8 | runner 用 RoleID + SecretID 向 Vault 登录 |
| 9 | Vault 返回**只有读特定机密权限**的 token |
| 10 | runner 用这枚 token 从 Vault 取它真正需要的机密 |

这条流程为什么是"对的"？把它和 §8 的反模式对照看会更清楚——这里先
直接给关键观察：**worker 持有自己的 Vault token 和 wrapping token，但
从来不接触 SecretID 明文；RoleID 则不在 worker 手里，而是在 runner
启动时由其他渠道（环境变量、镜像构建期注入等）注入**。"两半凭据同
时在场"的位置**只有 runner 一处**。

### 6.2 worker 自己应该用哪种 token 取 SecretID

worker 自己的 token 应当**严格限制范围**，只能取 wrapped SecretID，
其它什么都不能干。这枚 worker token 既可以是预置的长期 token，也可以
是一对硬编码的 RoleID + SecretID——**这本身风险很小**，因为这对凭据
**只能换出一种东西**：wrapped SecretID。

worker 这种用途的策略例子：

```hcl
path "auth/approle/role/+/secret*" {
  capabilities = [ "create", "read", "update" ]
  min_wrapping_ttl = "100s"
  max_wrapping_ttl = "300s"
}
```

> 注意上面策略示例里的 `min_wrapping_ttl` / `max_wrapping_ttl` 两个
> ACL 字段——它们把这条 secret-id 请求允许的 wrapping TTL 限定在
> 100–300 秒之间。配上这一道策略限制，broker 想取得"裸 SecretID"就会在
> 此处被拦下。

> worker 实际取 wrapped SecretID 的命令很短：
> ```shell-session
> $ vault write -wrap-ttl=120s -f auth/approle/role/my-role/secret-id
> ```
> worker **只需要知道 role 的名字**（这里是 `my-role`），完全不需要
> 知道这个 role 的 RoleID。

### 6.3 runner 真正登录后拿什么策略

runner 用 RoleID + SecretID 登录拿到的 token，策略也只覆盖"它这次任
务真正需要的那点机密"，比如：

```hcl
path "kv/my-role_secrets/*" {
   capabilities = [ "read" ]
}
```

---

## 7. Token 生命周期：用 batch token、复用 token、跑 Vault Agent

AppRole 登出来的是普通 Vault Token，但**应用使用 token 的方式**有几
条值得单独说的最佳实践。

### 7.1 优先用 batch token

[approle/index.mdx 开头那段](https://developer.hashicorp.com/vault/docs/auth/approle)
明确说：**推荐配合 AppRole 使用 `batch` token**。配置 role 时直接写
`token_type=batch`：

```shell-session
$ vault write auth/approle/role/my-role \
    token_type=batch \
    secret_id_ttl=10m \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40
```

为什么是 batch？原因很直接：**长 TTL 的 token 在百万级 AppRole
lease 清理时容易导致 Vault 服务端 OOM**——所以宁愿短 TTL + 配合续
期；如果是高吞吐认证（每秒上千次登录）的场景，则首选 batch token——
它**直接从内存签发、不消耗 storage**。

> batch token 的关键特征：从内存签发、不消耗 storage，适合高吞吐
> 认证场景。

> ⚠️ 一个 corner case：如果你的 approle 签发出来的 token **本身还需要
> 创建子 token**（比如要进一步签发临时凭据给下游），需要把
> `token_num_uses` 设成 0；否则 token 一旦达到 `token_num_uses` 上限
> 就用不动了。

### 7.2 优先复用 token，而不是每次重新登录

跟所有 auth method 一样：**让应用复用同一枚 token 重复取机密，比每次
都重新认证好得多**。认证本身是个"重操作"，签出来的 token 也要被 Vault
跟踪——重复认证既慢、又会给 Vault 增加跟踪开销。

### 7.3 让 Vault Agent 替你管 token

更进一步，可以在客户端跑 [Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)
**专门负责 token 的生命周期**——登录、续期都交给 Agent，应用程序不
必再自己实现 Vault API 调用，也不用关心 token 什么时候到期。

---

## 8. 反模式（Anti-patterns）：常见错误的归纳

本节集中盘点几种"看起来差不多但其实违反原则"的常见错误，把它们和
§6 的推荐范式并排展示。这一节可以当 trusted broker 范式的"反向校验
题"来读。

### 8.1 反模式 A：worker 自己取机密、把机密本身传给 runner

> "worker 反正都已经认证过了，干脆替 runner 把机密一并取出来交给
> 它。"

为什么不行？——一个 worker 通常会跑各种各样的 job、每个 job 需要不
同的机密；这套做法等同于**给 worker 配一张"能取所有应用机密"的大
policy**，而 worker 本身**根本不是这些机密的最终消费者**。任何一份
机密被泄漏，由于"读取者"身份模糊，**根本无法把告警关联到某一个具体
身份**——所有走过 worker 的机密都得当作被一起泄漏处理。

> 这条反模式直接破坏了 §1 引的两条根本原则之一——**Blast-radius of
> an identity**：每个认证身份只能访问它真正是 end-user 的那部分机密。

### 8.2 反模式 B：worker 把 RoleID 和 SecretID 一起递给 runner

> "我不让 worker 取机密，但让它取 RoleID 和 SecretID 然后传给 runner，
> 这样 worker 至少不知道机密本身了吧？"

仍然违反原则——worker **同时拿到了完整两半凭据**，意味着 worker 实
际上"具备"以 runner 身份登录 Vault 的能力。攻破 worker 等同于让攻击
者获得 runner 身份登录 Vault 的能力。这违反了 §1 那条 _RoleID 和
SecretID 唯一可同时出现的位置就是最终客户端_ 的中心原则。

### 8.3 反模式 C：worker 给 runner 派发"代签"的子 token

> "那我让 worker 直接拿自己的 token 给 runner 派一枚子 token，让子
> token 带上能取机密的 policy？"

依然不行——worker 现在持有可以**生成带取密 policy 的子 token** 的能
力；攻破 worker 等同于让攻击者拿到这一签发能力，可以借此获取下游机
密。这条比 8.2 更隐蔽，但本质风险一样。

### 8.4 反模式判别表

| 模式 | worker 拥有什么 | runner 拥有什么 | 是否反模式 | 根因 |
| :--- | :--- | :--- | :--- | :--- |
| 推荐范式 | worker token + wrapping token（不接触 SecretID 明文） | RoleID + SecretID + 最终 token | ✅ 不反 | 两半只在 runner 凑齐 |
| 反 A | 全部应用机密的明文 | 机密的明文 | ❌ 反 | 大 policy + 身份模糊 |
| 反 B | RoleID + SecretID | RoleID + SecretID | ❌ 反 | 两半在 worker 凑齐 |
| 反 C | 可签发带取密 policy 的 token | 子 token | ❌ 反 | worker 拥有签发能力 |

---

## 9. 安全考量：把 broker 当作关键系统对待

trusted broker 模式下，broker（这里就是 worker / 调度器）必须当**关
键系统**对待。访问要最小化、要监控、要审计。Vault 的审计日志带时间
戳，可以基于审计日志做两个关键告警：

1. **某个 AppRole 的 wrapped SecretID 被请求了，但根本没有对应的 job
   在跑**
2. **agent 尝试 unwrap 一枚已经被使用过的 wrapping token 时被 Vault
   拒绝**

任意一种事件命中，都说明 trusted broker 工作流可能已被攻陷，必须立
即调查。

---

## 10. 实验

下一步进入实验：在 Killercoda 上启用 AppRole，跑一遍 Pull 模式 +
CIDR 限制 + Response Wrapping + 反模式对照演示，并把每一节的字段都
亲手验证一次。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-app-role" title="实验：AppRole 认证完整动手——Pull 模式、CIDR 约束、Response Wrapping、反模式现场" />

---

## 参考文档

- [Use AppRole authentication](https://developer.hashicorp.com/vault/docs/auth/approle)
- [Best practices for AppRole authentication](https://developer.hashicorp.com/vault/docs/auth/approle/approle-pattern)
- [AppRole API](https://developer.hashicorp.com/vault/api-docs/auth/approle)
- [Response Wrapping 概念](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping)
- [Token TTL & 周期 token](https://developer.hashicorp.com/vault/docs/concepts/tokens#token-time-to-live-periodic-tokens-and-explicit-max-ttls)
- [How (and Why) to Use AppRole Correctly in HashiCorp Vault](https://www.hashicorp.com/blog/how-and-why-to-use-approle-correctly-in-hashicorp-vault)
