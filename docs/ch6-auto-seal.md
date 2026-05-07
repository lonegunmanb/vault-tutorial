---
order: 63
title: 6.3 自动化云端解封（Auto-Seal）机制对接（AWS KMS, Azure Key Vault, Transit 代理）
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.3 自动化云端解封（Auto-Seal）机制对接（AWS KMS, Azure Key Vault, Transit 代理）

> **核心结论**：`seal` 块用于声明 Vault 在启动时如何获得保护根密钥（root key）的最外层封印密钥。该块本身是**可选的**——若不声明，Vault 默认会用 Shamir 算法把根密钥拆成若干分片，每次启动都需要操作员手动重组解封；若声明，Vault 会改为在启动时调用外部 KMS / HSM 解密根密钥，实现免人值守的自动解封（auto-unseal）。Vault 开源版（Community Edition）原生支持 Shamir 与主流公有云 KMS 的 auto-unseal，而 Enterprise 版在此基础上额外提供 HSM unseal 与 seal wrap 数据保护层。

本节是第 6 章配置文件深入系列的第三节，建立在 6.1 节"`seal` 是可选顶层块"与 6.2 节"listener 是必填顶层块"之上，目标是把 `seal` 块的语义、可用类型、AWS KMS 形式的完整参数面、认证凭据查找顺序、密钥轮转语义以及与 Recovery Keys 的关系讲清楚。本节配套的互动实验基于 LocalStack 模拟 AWS KMS，让学员在零真实云成本的前提下完成一次完整的 auto-unseal 闭环。

> 关于"为什么需要解封、Barrier / Root Key / DEK 的三层密钥结构、Shamir 分片的密码学含义"等概念性内容，第 2.2 节已经系统讲解过；本节不再重复，重点放在"如何在配置文件中正确写出 `seal` 块"。

---

## 1. `seal` 块在 Vault 配置文件中的位置

`seal` 是一个顶层块，用于声明 Vault 使用哪一种封印类型来对根密钥进行额外的数据保护——通常是借助 HSM 或云 KMS 来加密 / 解密根密钥；该块是**可选的**。如果不声明，Vault 在面对根密钥时会自动退化为使用 Shamir 算法对其进行密码学分片。

`seal` 块的书写形式与 `storage` / `listener` 一样，块名后面紧跟一个字符串 label 用于声明使用哪一种实现。最小骨架如下：

```hcl
seal [TYPE] {
  # ...
}
```

例如声明使用 PKCS#11 协议对接 HSM：

```hcl
seal "pkcs11" {
  # ...
}
```

本节只覆盖与开源版直接相关的 `seal "awskms"` 形式，并简要说明同一份骨架在其它云厂商上的对应类型；HSM（`pkcs11`）形式以及 Enterprise 专属的 seal wrap 增强不在本节展开。

![seal 块在 Vault 配置文件中的位置：与 storage、listener 平级的顶层块，可选](/images/ch6-auto-seal/seal-stanza-position.png)

---

## 2. 配置文件中环境变量优先于配置项

对于那些**同时也能从环境变量读取**的配置选项，环境变量给出的值优先于配置文件中写出的值。

这一规则在自动化部署中尤其重要：CI/CD 流水线或 systemd unit 文件可以把敏感字段（如 AWS access key）从配置文件中剔除，改为通过受保护的环境变量注入，而不必担心被静态配置覆盖；同一份配置文件因此可以安全地分发给多套环境。

---

## 3. 间接值引用（Indirect Value References）：避免把机密写进配置文件

某些被认定为敏感的配置选项支持一种特殊的"间接引用"语法：选项的值不是机密本身，而是一个 URL 风格的指针，指向真正机密的来源。Vault 在加载配置时会跟随该指针解析出最终值。当前共支持三种 URL 形式：

| 形式 | 含义 |
| :--- | :--- |
| `env://NAME` | 最终值取自名为 `NAME` 的环境变量内容。 |
| `file://PATH` | 最终值取自路径 `PATH` 处文件的全部内容；路径可绝对可相对，相对路径相对于 Vault 进程的工作目录。 |
| `string://DATA` | 最终值就是 `string://` 之后的全部字符串本身——用于在确实需要写一段恰好以前述两种前缀打头的字面量字符串时进行转义。 |

> **重要警告**：间接值引用**不会**自动剥离前后空白；尤其是 `file://` 形式，需要特别留意源文件末尾的换行符——Vault 会原样把换行符纳入最终值。

这一机制为 `seal` 块带来重要的安全收益：AWS access key、secret key、session token 这三个高度敏感的字段都被官方明确允许使用间接引用，从而可以做到"配置文件本身完全可纳入版本控制，机密则单独通过环境变量或受 root 权限保护的文件注入"。

---

## 4. Auto-Unseal 与 Seal Wrap 的边界：哪些是开源版能用的

下面这条边界关系到本节的全部教学内容是否成立，必须先明确说清楚：

- **Auto-unseal 在所有 Vault 版本中都可用**——包括开源版（Community Edition）。
- **Seal wrap 仅 Vault Enterprise 提供**，且在 Enterprise 上**默认即启用**。
- 启用了 seal wrap 的 Enterprise 集群对 KMS 服务的可用性要求更高：KMS 不仅要在解封时可达，还必须在**整个运行期间**持续可达，而不仅仅是启动一瞬间。

由此可以得出本节的两个直接结论：

1. 开源版只用 KMS 解封根密钥，KMS 的可用性窗口仅限于 Vault 启动这一瞬间。一旦 Vault 解封成功，根密钥就驻留进程内存，KMS 短暂宕机不会立刻让正在运行的 Vault 拒绝服务；只有当 Vault 进程**重启**且此时 KMS 不可达，才会卡在 sealed 状态无法启动。
2. 本节在 LocalStack 上演示的全部流程都是 auto-unseal 流程，**不涉及** seal wrap；本课程也不会教 seal wrap 的具体配置。

---

## 5. Vault 社区版支持的解封方法

按官方对比口径，Vault 社区版（Community Edition）支持两类解封方法：Shamir 与"主流公有云的 cloud auto-unseal"；Vault Enterprise 在此基础上额外提供基于 HSM 的解封。

社区版可用的云端 auto-unseal 后端共有 5 种，每种对应一个独立的 `seal "<TYPE>"` label：

| Seal label | 对应云厂商的 KMS 服务 |
| :--- | :--- |
| `seal "awskms"` | AWS KMS |
| `seal "azurekeyvault"` | Azure Key Vault |
| `seal "gcpckms"` | GCP Cloud KMS |
| `seal "alicloudkms"` | 阿里云 KMS |
| `seal "ocikms"` | Oracle Cloud Infrastructure KMS |

无论选用哪一种 cloud-provider 后端，其底层运作逻辑都是一致的：根密钥不再通过分片机制保护，而是被生成并存储于该云厂商的 KMS 服务中；Vault 启动时凭借 IAM / 工作负载身份去 KMS 取回该密钥并完成自动解封。

> 使用任何一种云端 KMS 进行 auto-unseal，都意味着把根密钥的最终信任根委托给了该云厂商，需要把这一点纳入安全策略评估。

本节后续具体参数面以 `seal "awskms"` 为代表展开；其它四种 label 的字段集合在概念上对应（都需要某种"凭据 + 区域 / 账号 + key 标识符"），具体字段差异请查阅各 label 的官方文档。

---

## 6. 何时应当从 Shamir 切换到 Auto-Unseal：运维成本视角

Shamir 作为默认方法，依赖多名操作员（每人持有一份分片）协同到场才能解封 Vault；这意味着对企业级部署而言，每次 Vault 重启或扩容都需要协调多人，操作开销较高。

如果坚持使用 Shamir 模式，官方建议至少配套以下额外的运维流程：

- 每季度组织一次解封演习，确保所有持片操作员都能按预案响应；
- 分片应妥善存放在安全位置，并使用每位持有者的个人加密手段进一步包封；Vault 的 [`init` 命令](https://developer.hashicorp.com/vault/docs/commands/operator/init) 提供 PGP 加密 unseal keys 与 root token 的标志；
- 持片人对密钥的访问权应与企业用户生命周期管理（入职 / 离职流程）联动，避免人员变动时的信任失配。

> 与之对比，公有云 auto-unseal 的运维优势就非常明显：Vault 重启时无需任何人到场，依赖关系简化为"Vault 进程能否调通 KMS API"。代价则是必须为云厂商的访问凭据本身建立一层额外的安全保护。

---

## 7. `seal "awskms"` 完整参数面

下表列出 `seal "awskms"` 块的全部可用字段及其默认值。

| 字段 | 默认 / 是否必填 | 含义 |
| :--- | :--- | :--- |
| `region` | `"us-east-1"` | KMS 密钥所在 AWS 区域。若不在配置文件中给出，可由 `AWS_REGION` 或 `AWS_DEFAULT_REGION` 环境变量、`~/.aws/config` 文件、或 EC2 实例元数据补全。 |
| `access_key` | 必填 | Vault 调 AWS API 用的 access key ID。也可通过 `AWS_ACCESS_KEY_ID` 环境变量或 AWS CLI 配置文件 / 实例配置文件提供。 |
| `session_token` | `""` | AWS 会话令牌；可通过 `AWS_SESSION_TOKEN` 环境变量提供。 |
| `secret_key` | 必填 | Vault 调 AWS API 用的 secret access key。也可通过 `AWS_SECRET_ACCESS_KEY` 环境变量或 AWS CLI 配置文件 / 实例配置文件提供。 |
| `kms_key_id` | 必填 | 用于加密 / 解密的 AWS KMS 密钥 ID 或 ARN。也可通过 `VAULT_AWSKMS_SEAL_KEY_ID` 环境变量提供；亦支持 `alias/<key-alias-name>` 形式的密钥别名。 |
| `disabled` | `""` | 若 Vault 正在执行**从 auto seal 配置迁移走**的过程，应设为 `"true"`；否则应设为 `"false"`。 |
| `endpoint` | `""` | 用于发起 AWS KMS 请求的自定义 API 端点。也可通过 `AWS_KMS_ENDPOINT` 环境变量提供。当通过 VPC Endpoint 连接 KMS 时尤为有用；不设置则 Vault 使用对应区域的默认 API 端点。 |

完整的官方示例如下，把上述字段全部显式写出：

```hcl
seal "awskms" {
  region     = "us-east-1"
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  kms_key_id = "19ec80b0-dfdd-4d97-8164-c6examplekey"
  endpoint   = "https://vpce-0e1bb1852241f8cc6-pzi0do8n.kms.us-east-1.vpce.amazonaws.com"
}
```

> **关于把 access key / secret key 写进配置文件这件事**：尽管配置文件允许把 `AWS_ACCESS_KEY_ID` 与 `AWS_SECRET_ACCESS_KEY` 作为 seal 参数原样写出，官方**强烈建议**改为通过环境变量提供这两个值。

---

## 8. 激活 `awskms` seal 的两条等价路径

Vault 进程会通过两种等价方式判断当前是否启用了 AWS KMS auto-unseal：

1. 配置文件中存在一个 `seal "awskms"` 块；
2. 环境变量 `VAULT_SEAL_TYPE` 被设为 `awskms`。如果选择这条路径，则其它所有 AWS KMS 专属变量（特别是 `VAULT_AWSKMS_SEAL_KEY_ID`），以及一组能完成 AWS 鉴权所需的 AWS 通用变量（`AWS_ACCESS_KEY_ID` 等），都必须同时设置妥当。

可用于这条"全环境变量"路径的两个 seal 专属变量是：

- `VAULT_SEAL_TYPE`
- `VAULT_AWSKMS_SEAL_KEY_ID`

> 实际部署中，最常用的混合方案是：把 `region` / `kms_key_id` 这类**非机密、不易变**的字段放进配置文件以便代码评审与版本控制；把 `access_key` / `secret_key` 这类**机密、按环境而异**的字段交给环境变量、IAM 实例配置文件或工作负载身份联合提供。

---

## 9. AWS 凭据来源的查找顺序

当配置文件中没有显式给出 `access_key` / `secret_key` 时，Vault 内部使用的官方 AWS SDK 会按如下固定顺序在外部环境中寻找凭据：

1. **配置参数中显式给出的 AWS 专属值**（`access_key` / `secret_key` / `session_token` / `region`）；
2. **环境变量**（`AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_REGION` / `AWS_DEFAULT_REGION`）；
3. **共享凭据文件**（典型路径 `~/.aws/credentials`，由 AWS CLI 维护）；
4. **IAM Role / ECS Task 凭据**（运行在 EC2 实例上时通过实例元数据获得，运行在 ECS 容器上时通过任务角色获得）。

理解这一顺序的实际意义在于：在生产 EC2 环境下，**最佳实践是把 access key / secret key 都不写进配置文件、也不写进环境变量**，而是给 Vault 所在 EC2 实例附加一个最小权限的 IAM 角色，让 SDK 自动从实例元数据获取临时凭据；这样 Vault 配置文件就不会出现任何长效凭据。

![Vault AWS SDK 凭据查找的四级回退链](/images/ch6-auto-seal/aws-credential-chain.png)

---

## 10. Vault 需要在 KMS 密钥上拥有的最小权限集

Vault 在 KMS 密钥上需要的权限只有以下三个 API 动作：

- `kms:Encrypt`
- `kms:Decrypt`
- `kms:DescribeKey`

授予方式有三条等价路径：通过 Vault 所用 IAM principal 的 IAM 策略授予；写入 KMS key policy；或通过 KMS Grants 在密钥上单独授权。

官方在 Best Practices 文档中进一步给出 EC2 部署形态下的推荐策略骨架：用 Instance Profile 把上面三条 API 动作绑定到**单一**密钥的 ARN（`Resource` 字段只列那一条 ARN，避免授权扩散到其它密钥）：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
      "Resource": ["${kms_arn}"]
    }
  ]
}
```

与之配套的两条同样重要的最佳实践：

- **最小化密钥管理权限**：只让最少数量的人能管理这把 KMS 密钥，且只让 Vault 这一个进程能读它；
- **开启 CloudTrail 审计**：为这把 KMS 密钥单独打开 CloudTrail 审计日志，并定期复核日志，确认没有 Vault 之外的调用方在尝试访问；
- **Vault 独占实例**：不要让 Vault 与其它服务共享 EC2 实例。

---

## 11. KMS 密钥的轮转语义

`seal "awskms"` 支持 KMS 端的**根密钥轮转**——既支持 AWS KMS 提供的自动轮转，也支持手动轮转。这一支持之所以可行，是因为加密数据本身在落盘时同时记录了用以加密它的 KMS 密钥版本信息。

由此衍生出两条必须遵守的运维规则：

1. **旧版本密钥不得 disable 或 delete**——它们仍被用于解密历史数据；
2. **新写入或更新的数据会用当前最新版本的密钥加密**，"当前版本"由 `seal` 块中给出的 `kms_key_id` 决定；如果 `kms_key_id` 写的是 `alias/...` 形式的别名，则别名当前所指向的版本即为"当前"。

> 在轮转密钥的工程实践中，建议直接使用 alias 而非具体 key ID 来填写 `kms_key_id`：alias 是稳定的人类可读名称，背后指向哪个具体版本由 KMS 端负责维护，因此 Vault 配置文件本身在轮转密钥时**完全不需要修改**。

---

## 12. 切换 seal 方法：迁移流程与 `disabled` 字段的语义

切换 seal 方法（例如从 Shamir 迁移到 AWS KMS、或从 AWS KMS 迁回 Shamir、或从一种云 KMS 迁移到另一种云 KMS）必须按官方的 [seal migration](https://developer.hashicorp.com/vault/docs/concepts/seal#seal-migration) 流程进行。

`seal "awskms"` 块中的 `disabled` 字段就是为这一迁移流程而存在：当 Vault 正在从一份 auto seal 配置中迁移**离开**时，应当把这一字段设为 `"true"`；其它情况下应保持为 `"false"`。

> seal migration 本身的具体步骤（init / unseal / 配置文件改动顺序、何时停 Vault 进程、何时切换 `disabled` 等）是一套独立的运维流程，本节不展开；本课程的 [5.8 节](/ch5-mount-migration) 已专门讲过 mount migration，与本节的 seal migration 不是同一回事，请勿混淆——前者迁移的是某个已挂载的引擎或认证方法的 API 路径，后者迁移的是整个集群的封印密钥来源。

---

## 13. Recovery Keys：auto-unseal 模式下的"另一把钥匙"

只要 Vault 用 HSM 或云端外部密钥进行封印，初始化时返回给操作员的就**不是** unseal keys，而是另一组叫做 **recovery keys** 的分片。这组分片日常并不参与解封——日常解封由外部 KMS 自动完成；但在执行某些**高度特权**的操作时仍然必不可少，例如生成新的根密钥（generating new root keys）。

这组分片必须按 Shamir 模式下保护 unseal keys 的同等标准妥善保管：分人持有、PGP 包封、与人员生命周期管理联动。失去全部 recovery keys 在 auto-unseal 模式下并不会立刻导致集群无法启动（KMS 仍能解封），但会导致一旦 root token 丢失就无法重新生成新 root token，集群失去最高权限管理能力。

![Shamir 模式下的 unseal keys 与 auto-unseal 模式下的 recovery keys：日常用途完全不同](/images/ch6-auto-seal/recovery-vs-unseal-keys.png)

---

## 14. AWS 实例元数据查询超时

`seal "awskms"` 文档在最末段以 include 形式引入了一段关于"AWS 实例元数据查询超时"的共享段落，提示在 EC2 实例上运行 Vault 时，凭据查询会涉及实例元数据服务（IMDS）的请求超时设定。

由于该段落的具体内容由 HashiCorp 文档 build 系统在编译期注入，本节不展开其具体调参细节。在 LocalStack 环境（无 IMDS）以及通过环境变量提供凭据的场景下，该段落不影响实际运行。

---

## 15. 推荐的 6.3 节"AWS KMS auto-unseal"基线总结

把上文要点合并成一份可以直接抄用的、**EC2 上以 IAM 实例配置文件提供凭据 + KMS alias 提供密钥指针 + 显式 region**的 `seal "awskms"` 范例。这份基线刻意**不写**任何 `access_key` / `secret_key`，让 SDK 沿凭据查找链回退到实例元数据：

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-prod-unseal"
}
```

如果运行环境无法使用实例元数据（例如本机 / 容器内没有 EC2 metadata 服务），推荐改用环境变量提供凭据，同样保持配置文件中无机密字段：

```bash
# Vault systemd unit 或容器启动脚本：
export AWS_REGION=us-east-1
export AWS_ACCESS_KEY_ID=...    # 从受保护机密管理系统注入
export AWS_SECRET_ACCESS_KEY=... # 从受保护机密管理系统注入
```

```hcl
seal "awskms" {
  kms_key_id = "alias/vault-prod-unseal"
}
```

只在**实在没有任何外部机密注入手段**的情况下，才退而求其次把 access key / secret key 直接写进配置文件，且必须配合间接值引用降低泄露面：

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-prod-unseal"
  access_key = "env://AWS_ACCESS_KEY_ID"
  secret_key = "file:///etc/vault.d/aws_secret_key"
}
```

---

## 16. 互动实验

本节配套了一个 Killercoda 实验，学员将基于 LocalStack 模拟的 AWS KMS 服务，**亲手把一个 Shamir 模式的非 dev raft Vault 升级为 AWS KMS auto-unseal**，并通过若干实际操作验证本节几个最重要的边界行为。完成下列练习：

- **Step 1**：启动 LocalStack（仅 KMS 服务），用 awscli 在 LocalStack 上创建一把 KMS 密钥并赋予 alias。
- **Step 2**：架设一个 `socat` TCP 代理作为 Vault 与 LocalStack 之间可宕机的中转层；在原本只声明了 `storage` / `listener` 的 `vault.hcl` 上追加一个 `seal "awskms"` 块，把 `endpoint` 指向代理端口（同时演示间接值引用与 endpoint 的实际作用），重启 Vault。
- **Step 3**：执行 `vault operator init`，亲眼观察输出**不是** unseal keys，而是 recovery keys + root token。
- **Step 4**：直接 `kill` Vault 进程并再次启动，观察 Vault **无需任何人工解封步骤**就回到 unsealed 状态——这就是 auto-unseal 在工作。
- **Step 5**：杀掉 `socat` 代理进程模拟 KMS 不可达，先验证 Vault 进程还在跑时业务不受影响；再重启 Vault 复现"KMS 不可达 → Vault 启动失败"的故障路径；最后拉起代理，验证 Vault 重启即可干净 auto-unseal。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-auto-seal" title="实验：用 LocalStack 模拟 AWS KMS 完成 Vault auto-unseal 全闭环" />
