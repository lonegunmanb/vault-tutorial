---
order: 42
title: 4.3 AWS 认证：用云平台身份直接登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.3 AWS 认证：用云平台身份直接登录 Vault

> **核心结论**：AWS 认证方法（`aws`）让 IAM principal 与 EC2 实例
> **不需要任何由人工预先下发的 Vault 凭据**就能登录 Vault——它属于
> [4.2 章 §1](/ch4-app-role) 区分过的"可信第三方（trusted
> third-party）"模式：信任根放在 AWS 自己（IAM / EC2 元数据签名），
> Vault 只负责验证 AWS 给出的"身份证明"。它包含两套互不兼容、各自
> 适用不同场景的子方法——`iam`（基于签名后的 `sts:GetCallerIdentity`
> 请求）与 `ec2`（基于 EC2 实例身份文档的 PKCS#7 签名）；新设计的应
> 用首选 `iam`。本章把这两套机制各自的认证流程、可绑定的约束、
> "推断（inferencing）"机制、混用规则、Client Nonce / Role Tag /
> Deny List 等高级选项一一讲清，再用动手实验把 `iam` 与 `ec2` role
> 的配置、约束验证、与 Vault 端"看不见 AWS"时的失败现场全部跑一遍。

参考：
- [AWS Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/aws)
- [AWS Auth API](https://developer.hashicorp.com/vault/api-docs/auth/aws)

---

## 1. AWS 认证在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 那张分类表：AWS 认证落在"平台/工作负
载身份型"该类别——与 `kubernetes`、`gcp`、`azure`、`alicloud`、`jwt`
平起平坐。它的本质是把 AWS 这个外部权威**作为可信第三方**：Vault 不
存任何关于"这个 IAM 用户是不是真的某个应用"的判断，所有的身份证明
都由 AWS 自身给出（IAM 签名、EC2 实例身份文档），Vault 仅负责验证这
些证明的真伪。

`aws` 这个 auth method **同时包含**两种认证类型：`iam` 与 `ec2`。
Vault 会**根据登录时携带的参数**自动判断采用哪一种——不需要显式选择
何种端点，但**单个 role** 在创建时必须固定一种 `auth_type`，创建后不
可修改。

> **官方明确推荐 `iam` 优先**：`ec2` 方法是早期 AWS 尚未提供
> `sts:GetCallerIdentity` 时的产物，`iam` 在其之上更为灵活、更贴近现代
> 访问控制最佳实践。

---

## 2. `iam` 认证流程：让 AWS 替 Vault 验签

`iam` 认证的核心机制：客户端使用本地的 AWS 凭据，按 [AWS Signature v4
算法](http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html)
对一次空的 `sts:GetCallerIdentity` 请求签名，再将这次"已签好但尚未
发送"的请求**整体**（URL、body、headers、HTTP method 四件套）提交
给 Vault。Vault 接收后将四件套重组成完整请求，转发给真正的 AWS
STS 服务；STS 验证签名通过后会返回这次签名对应的 IAM principal是
谁——Vault 据此即可确认调用方的 IAM 身份。

签名所需的 AWS 凭据来源**完全不受限制**——可以来自 EC2 实例的元数据服务、
来自 Lambda 函数运行时注入的环境变量，原则上"任何能获取一对 AWS
凭据的位置"都可以。这意味着客户端**无需具备直接访问 STS 端点的网络
能力**——只需能完成请求签名即可；真正需要访问 STS 端点的是 Vault 服务器。

每次签发的 AWS 请求都携带当前时间戳，这本身属于 AWS 算法层为防
重放设计的机制——AWS 签名 15 分钟后自动失效。除此之外，Vault 还允许（
并强烈建议）**额外要求一个特定 header**：`X-Vault-AWS-IAM-Server-ID`，
其值由运维写到 `auth/aws/config/client` 的 `iam_server_id_header_value`
字段。该 header 必须出现在签名覆盖的 header 集合里——这样它就受
AWS 签名保护，攻击者无法伪造，可以防止"从开发环境 Vault 窃取一份签名
请求转用于攻击生产 Vault"。

> **协议层细节**：AWS 端虽然同时支持 GET / POST 形式的签名请求，但
> Vault 的 aws auth 只接受 **POST** 形式，且**不支持 presigned 请求**
> （即将签名信息放入 `X-Amz-Credential` / `X-Amz-Signature` /
> `X-Amz-SignedHeaders` 三个 GET 查询参数那种形态）。

> **MFA 不会被 Vault 强制**：AWS 在 `GetCallerIdentity` 上**没有任何
> 鉴权检查**——即便你给某 IAM 凭据加了"必须 MFA 才能用"的 IAM
> policy，没经过 MFA 的原始凭据照样能调用 `GetCallerIdentity`、照
> 样能用来通过 `iam` 方法登录 Vault。"登录 Vault 时强制 MFA"在这套
> 机制下做不到。

---

## 3. `ec2` 认证流程：由 AWS 为 EC2 实例签发身份凭证

`ec2` 认证利用了 EC2 元数据服务里的另一份资产：**Instance Identity
Document**——一份描述实例的 JSON（含 region、AMI、instance ID、
pendingTime 等），由 AWS 配套生成一份 PKCS#7 签名，并按 region 公开
对应的公钥。

完整数据流：实例从元数据服务取 PKCS#7 签名 → 将签名发送给 Vault →
Vault 用公钥验签，确认该文档是 AWS 签发且未被篡改 → 作为额外校验，
Vault 还会调用 EC2 公开 API 确认该实例当前仍在运行 → 验证通过后签发初始
Vault token。

> 这条原始数据流之上还可以叠加多道安全加固机制：Client Nonce、Role Tag、
> Deny List、Instance Migration——后续 §6 / §7 / §8 / §9 逐一讲解。

---

## 4. Authorization 工作流：role 与可绑定约束

**机制层是 per-role 的**：在 aws auth 下注册若干 role，每个 role 在
创建时绑定一种 `auth_type`（`iam` 或 `ec2`），**创建后不可改**。
role 上还可以挂各种约束（policy 列表、token max TTL、实例必须来自哪
些 AMI 等等）；约束如果是列表形式，**只要登录时命中列表里任意一个
值**就算通过，不要求全部命中。

`iam` 类型的 role 上，最关键的约束是 `bound_iam_principal_arn`——指
定允许登录的 IAM principal ARN 列表。它支持**结尾通配**：
`arn:aws:iam::123456789012:*` 允许该账号下任何 principal 登录；
`arn:aws:iam::123456789012:role/*` 允许该账号下任何 IAM role 登录。
但凡使用了通配符，Vault 必须有 `iam:GetUser` 与 `iam:GetRole` 权限
来解析出完整的 user path。

**ec2 类型的 role 上能加的约束**则更"实例化"：可以绑定 AMI ID、绑
定 instance profile、要求实例带特定的 role tag。"专门面向 EC2 实例
的约束"原则上只在用 `ec2` 方法登录时才会被检查；但是 `iam` 方法上
启用 inferencing 后，也可以应用部分这类约束（见 §5）。

> **role tag 是什么**：很多组织会用同一份"种子 AMI"启动若干实例，
> 启动后才被配置管理工具差异化。这种场景下，AMI 这个维度区分不出
> "这是哪一类机器"——`role_tag` 让 Vault 通过实例上的某个 tag 值再做
> 一次细分。Tag 的值由 `auth/aws/role/<role>/tag` 端点生成、HMAC 签
> 名，**只能用来在 role 已有约束之上进一步收紧**，不能授予额外权限。

> 一旦 role 启用了 `role_tag` 且实例上没有该 tag（或被人手动删了），
> 认证直接失败——这是为了防止"通过删 tag 来越权"。

---

## 5. IAM 推理（inferencing）：让 `iam` 也能识别"这是个 EC2 实例"

正常情况下，`iam` 方法只能告诉 Vault "登录的是哪个 IAM principal"
（IAM user / role）。但如果一台 EC2 实例挂在某个 IAM instance
profile 下，AWS 会替它调 `sts:AssumeRole`，调用时把 `RoleSessionName`
设成实例的 instance ID——Vault 看到的 ARN 形如
`arn:aws:sts::123456789012:assumed-role/MyRole/<instance-id>`，从这
里就可以"推断出"调用方是哪台 EC2 实例。

启用推理之后，role 上可以追加"原本只属于 ec2 方法"的约束
（如 AMI ID 绑定、instance profile 绑定等）——`iam` 登录时这些约束
也会被检查。

> **推理的安全前提**：如果除了 AWS 自己（`ec2.amazonaws.com`
> service principal）以外**还有别的实体**被允许 AssumeRole 这个 role，
> 那个实体就可以**任意指定 RoleSessionName**——也就是可以伪装成
> 任何一台 EC2 实例对 Vault 登录。同样，能修改这个 role 信任策略的
> 人（拥有 `iam:UpdateAssumeRolePolicy`）也能间接做到这一点。所以使
> 用 iam 推理的前提是：严格管控该 role 的 AssumeRole 调用方与
> 信任策略的修改权限，并通过 CloudTrail 监控相关 API 调用。

---

## 6. 混用规则：单个 role 只能选一种 auth_type

Vault 不允许同一个 role 同时支持 ec2 与 iam，也**不支持 assumed
roles**（即同一个 role 既采用 ec2 又允许"代为 assume"）；进一步，Vault
会主动拦截"在选定 auth_type 下根本无法生效"的约束配置。

| 场景 | 配置 | 客户端能用哪个 auth_type 登录 |
| :--- | :--- | :--- |
| 1 | `auth_type=ec2` + `bound_ami_id=...` | 只能用 ec2 登 |
| 2 | `auth_type=iam` + `bound_iam_principal_arn=...` | 只能用 iam 登 |
| 3 | `auth_type=iam` + 启用 inferencing + `bound_ami_id` + `bound_iam_principal_arn` | 必须用 iam 登；`RoleSessionName` 必须是 Vault 能看到的 instance ID；该实例必须来自指定 AMI |

---

## 7. iam vs ec2：到底用哪个

官方花了整整一节做对比，浓缩成几条决策原则：

- **认证对象的范围**：`ec2` 只能认 EC2 实例，能基于 AMI、instance
  profile、role tag 做精细过滤；`iam` 认的是"AWS IAM principal"——
  IAM user、IAM role（含跨账号 assume）、跑在 IAM role 里的 Lambda、
  挂在 instance profile 里的 EC2 实例都算。`iam` 范围更广，但因为对
  象更通用，"细分到具体实例"的能力依赖 inferencing。
- **认证机制**：`ec2` 用的是相对静态的 instance identity document，
  Vault 必须额外加 client nonce、role tag、instance migration 等机
  制来防重放；`iam` 用的是 AWS 签名算法本身——signature 15 分钟过期、
  AWS secret key 永不上线，天然更难重放。
- **凭据被窃取的相对难度**：instance identity document 因为静态、易被
  窃取，但难以伪造；EC2 instance profile 的临时凭据短寿命且动态，难
  被窃取但相对容易"假冒来自 EC2"。
- **典型决策**：非 EC2 实体（IAM user / Lambda / 借助 AdRoll Hologram
  这类工具的开发笔记本）只能选 `iam`；纯 EC2 场景两者都行，但只要
  需要"基于 AMI 过滤"这种细粒度过滤、或要用 role tag，就只能选 `ec2`
  （或为每个 role 准备不同的 instance profile / 启用 inferencing）。

---

## 8. ec2 专属机制（一）：Client Nonce 与 TOFU

PKCS#7 签名默认对实例上**所有**进程可读——只要拿到，就能拿去 Vault
冒充该实例。Vault 用 **TOFU（Trust On First Use）** 思路加固：**第一
次拿签名来登录的客户端被信任**，登录后 Vault 把这台实例的 instance
ID 加进 `accesslist`；后续要再认证，必须出示一个 nonce——这个 nonce
是 Vault 在第一次登录时返回、并和 instance ID 一起记入 accesslist 的，
**只有原始客户端知道**。

**这个机制的副作用是"非法登录会自动暴露"**：如果攻击者提前用 PKCS#7
登了一次，那合法的实例下次登录会因为 nonce 不匹配被拒绝——运维就能
立刻发现"这台实例的签名已经泄漏"。这正是 Vault 用 accesslist 而不是
denylist 的原因——记的是"允许重新认证的客户端"，不是"禁止的客户端"。

> **可以禁用重认证**：role 上设 `disallow_reauthentication=true` 表
> 示一个实例只允许登录一次；适合 ASG 这种"一次启动、永不变"的场景，
> 配合大 max TTL 后 token 自然能用到实例销毁。

> **客户端可以预先指定 nonce**：第一次登录就传一个自定义 nonce 进
> 来——Vault 会绑到 accesslist 里，后续必须匹配这个值。建议用强随机
> 值；客户端自传的 nonce **不会**被审计日志记录，规避了 Vault 自动
> 返回 nonce 时被记入审计的隐忧。

---

## 9. ec2 专属机制（二）：丢 nonce 与 instance migration

实例重启 / 停起 / 异常重建时，存在客户端将缓存的 nonce 丢失的可
能——一旦丢失，正常的重新登录会被拒。常规做法是运维通过
`auth/aws/identity-accesslist/<instance_id>` 端点删掉对应条目，让该
实例可以重新进入"第一次登录"流程。

实例的 identity document 里有个 `pendingTime`：实例每次 stop/start 都
会刷新（reboot 不会）。`allow_instance_migration=true` 让 Vault 看到
"nonce 不匹配但 pendingTime 比 accesslist 里记录的更新"时，认定客户
端经历了一次 stop/start，允许它重新登录并替换 accesslist 里的 nonce。
等同于在 stop/start 时**重置了 TOFU 信任**——使用要谨慎。

> `allow_instance_migration` 也可以写在 role tag 里，但它**只能"放
> 宽限制"被 role 收紧、不能反过来**：role 上设 false、tag 上设 true
> 才会生效；role 上设 true 之后，tag 上写什么都没用。

---

## 10. role tag 进阶：动态策略 + Deny List

`role_tag` 可以把"角色权限的子集"写进 tag——具体存放方式是把内容
SHA256 哈希后用 per-role 密钥 HMAC 保护，密钥只存在 method 本地，
管理员篡改 tag 也无法越权（HMAC 验签会失败）。

如果 tag 创建时不指定 policy，登录后实例继承 role 上配的 allowed
policies；如果指定了 policy 字段但内容为空，则 token 只带
`default`——`default` 默认只允许操作自身 token 与访问 cubbyhole，可
以用来给实例一个"安全便签纸"用、但不开放任何其他 Vault 资源。

如果某个 role tag 被错误分发（比如 image build 流水线漏了过滤），可
以把它写入 `auth/aws/roletag-denylist/<role_tag>`——这条 tag 之后再
也无法用于登录。**已经签出去的 token 不会被吊销**——这个 deny list
仅阻止后续登录。

`identity-accesslist` 和 `roletag-denylist` 里的条目都有过期时间，由
"role 的 max_ttl、role tag 的 max_ttl、method mount 的 max_ttl"三者
最小值决定。Vault 内置的周期任务会自动清理过期条目（默认安全缓冲
72 小时——只清"过期超过 72 小时"的条目），也可以通过
`auth/aws/tidy/identity-accesslist` / `auth/aws/tidy/roletag-denylist`
端点手动触发清理。

---

## 11. 其他注意点

**变种公钥**：AWS 各 region 的 instance identity document 公钥并不
完全一样。Vault 已经内置了主公钥（覆盖大部分 region）；个别 region
若验签失败，运维需要通过 `auth/aws/config/certificate/<cert_name>`
注入对应公钥。

**dangling tokens**：实例登录后拿到 Vault token，之后实例如果异常下
线，Vault 不会立刻知道；token 仍然按 lease 有效，直到 TTL 到期或因
没人续期而过早失效。

**跨账号访问**：让 Vault 认证别的 AWS 账号下的 IAM principal 或 EC2
实例时，配置 `auth/aws/config/sts/<account_id>`：Vault 会通过
`sts:AssumeRole` 切换到目标账号下指定的 IAM role 来验证目标账号下的
实体。该 IAM role 在目标账号端要把"Vault 所在 master account"列为
信任实体；除了不需要再额外的 `sts:AssumeRole` 权限以外，其他权限要
求与 Vault 自身 IAM policy（§12）一致；同时 master account 那边要给
Vault 授 `sts:AssumeRole`。

---

## 12. 给 Vault 自己配的 IAM 权限

Vault 调用 AWS API 用的就是 `auth/aws/config/client` 里那对 key（或
等价的 instance profile / WIF 凭据）。官方推荐的最小 IAM policy 拆
成几段：

- **核心读**：`ec2:DescribeInstances`、`iam:GetInstanceProfile`、
  `iam:GetUser`、`iam:GetRole`——分别覆盖 ec2 方法的实例校验、
  `bound_iam_role_arn` 的 instance profile 解析、wildcard ARN 的
  IAM principal 解析。
- **跨账号 assume**：`sts:AssumeRole` 仅授给被显式列入跨账号配置的
  目标 role，每个目标 role 在目标账号侧都需要挂载与本表等价的 IAM
  policy（除 `sts:AssumeRole` 自身外）。
- **管理自身的 access key**：`ManageOwnAccessKeys` 这一段（含
  `iam:CreateAccessKey` / `iam:DeleteAccessKey` 等）仅在需要使用
  Vault 的 [Rotate Root Credentials](https://developer.hashicorp.com/vault/api-docs/auth/aws#rotate-root-credentials)
  接口轮换 Vault 自身使用的那对 key 时才需要。

> 如果同一个 Vault 既挂 aws 认证又挂 aws 机密引擎，权限要求要把两边
> 求并集——本表只覆盖认证侧。

> **企业版独有**：可以用 `rotation_schedule` / `rotation_window` /
> `disable_automated_rotation` 把 root credential 轮换变成定时任务
> （比如每周六零点）。开源版没这一组字段，仍需手工或借助
> `rotate-root` API 触发。

---

## 13. Plugin Workload Identity Federation (WIF)

> **企业版独有**。开源版了解即可。

aws auth engine 支持 plugin WIF——Vault 将自身一段 plugin identity
token（一枚 JWT）作为"换取 STS 临时凭据"的身份令牌，与 AWS 之间通
过 OIDC 信任关系交换；之后 engine 使用换取到的短期 STS 凭据调用 AWS
API，**不再需要在 `config/client` 里配长效 access key**。

配置步骤：将 Vault 的 plugin identity token issuer endpoint 暴露给
AWS（去掉 `/.well-known/openid-configuration` 后缀的部分作为 provider
URL）→ 在 AWS 创建 IAM OIDC identity provider → 创建 web identity
role（audience 与上一步保持一致）→ 在 Vault 写 `config/client` 时填
`identity_token_audience` 与 `role_arn`。换取得到的 STS 凭据默认 1
小时 TTL，自动续期。

---

## 14. CLI 登录形式速记

`ec2` 方法：先从实例元数据取 PKCS#7 签名，再 POST 给 login 端点。
官方示例从 `/rsa2048` endpoint 取签名，并通过 `pkcs7` 字段提交；
Vault 不支持 SHA-1 签名的 X.509 证书。

`iam` 方法：构造签名请求是个非标动作，Vault CLI 已经内建了支持——
直接 `vault login -method=aws header_value=... role=...`，CLI 会按
AWS SDK 的标准凭据查找顺序（环境变量 → `~/.aws/credentials` →
instance profile → ECS task role）找凭据。也可以显式从命令行传入
`aws_access_key_id` / `aws_secret_access_key` / `aws_security_token`
（不推荐）。

`region` 默认 `us-east-1`；可以指定具体 region 或写 `auto`（让 CLI
按 AWS 标准凭据查找规则推断）。务必保证 region 与目标 STS
端点一致；使用 GovCloud 时还要在 role 上设 `sts_endpoint`、
`sts_region` 为对应值，并在登录时显式传 `region=us-gov-west-1`（或
`-east-1`）。

---

## 15. AWS instance 元数据超时

官方在此处通过 `@include 'aws-imds-timeout.mdx'` 引入 IMDS 超时相关
说明，需要查看被 include 的文件才能展开具体内容。

---

## 16. 实验

下一步进入实验：在 Killercoda 上**用 MiniStack（本地 AWS API 兼容
服务）模拟 AWS**，完整运行 `iam` 方法的登录链路——`vault
login -method=aws` 会让 Vault CLI 使用本地 AWS 凭据签一次
`sts:GetCallerIdentity`、将请求四件套交给 Vault、Vault 转发到
MiniStack STS、STS 验签返回 ARN、Vault 据此签发 token。再分别演示
`bound_iam_principal_arn` 的精确匹配 / 通配符匹配，`ec2` 方法的配
置面与 mixing 拦截，以及 `identity-accesslist` / `roletag-denylist`
/ `tidy` 等运维端点。

> MiniStack 实现了 IAM / STS API 的子集，对 SigV4 验签足够真实——
> iam 链路在本地可以完整运行；但它**不模拟 EC2 实例的 PKCS#7 instance
> identity document 签名**，所以 `ec2` 方法只能演示配置面与拒绝路
> 径，不可能在本环境真正登录成功。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-aws" title="实验：AWS 认证完整动手——iam / ec2 双 role、mixing 限制、accesslist / denylist 端点" />

---

## 参考文档

- [AWS Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/aws)
- [AWS Auth API](https://developer.hashicorp.com/vault/api-docs/auth/aws)
- [AWS STS GetCallerIdentity](http://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html)
- [AWS Signature v4](http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html)
- [AWS Instance Identity Document](http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-identity-documents.html)
