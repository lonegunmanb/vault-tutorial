---
order: 33
title: 3.3 AWS 机密引擎：动态 IAM 凭据与租约即生命周期
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.3 AWS 机密引擎：动态 IAM 凭据与租约即生命周期

> **核心结论**：AWS 机密引擎是 Vault "动态机密"理念的代表作。它**不**
> 帮你存放 AWS 静态 Access Key，而是用一对管理员的 root key 当种子，
> 每次有应用来要凭据时**实时**调 AWS API 临时铸造一份**短寿命**的
> 凭据返还，并把这份凭据的删除时机绑定到 Vault 的 **Lease**（[2.3
> 章](/ch2-lease)）上——`vault lease revoke` 就会真的去 AWS 调
> `DeleteUser` / 让 STS Session 失效。这一节我们梳理清楚三种
> `credential_type` 的本质区别、它们各自调的是哪一个 AWS API、对应的
> 路径与 Policy 是什么，以及为什么 root key 在 Vault 里也得照样轮转。

参考：
- [AWS — Vault Secrets Engines Docs](https://developer.hashicorp.com/vault/docs/secrets/aws)
- [AWS Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/aws)
- [Lease 概念回顾](/ch2-lease)

---

## 1. 为什么需要"动态" AWS 凭据

把 AWS Access Key ID + Secret Access Key 直接写进 KV v2 也能用，但所有
"静态长效凭据"通病都会一并继承：

- **轮转成本极高**：一旦泄露，必须人工去 AWS 控制台改、再追着所有消费
  方更新——往往要做"双 key 并存的灰度"才能不中断业务
- **不知道"谁"在用**：审计日志只看到 `AKIAxxx` 在调 S3，至于这是
  CI/CD、是开发者笔记本、还是已经离职员工的备份脚本，事后根本理不清
- **scope 经常被放大**：本来只该读一个 bucket 的脚本，被偷懒授予了
  `s3:*`——因为运维不想为每个用例新建一对 key

AWS 机密引擎换一个思路：

1. 管理员只在 Vault 里配置**一对** root key，并写一组"模板" Role：
   "凡是叫 `s3-readonly` 的请求，就去 AWS 临时建一个只能读 S3 的 IAM
   User / 调一次 STS"
2. 应用来 Vault 取凭据时，Vault 当场调 AWS API 铸一份临时凭据
3. 这份凭据被 Vault 包成一个 **Lease**：到期、或被显式 revoke 时，
   Vault 自动去 AWS 把对应的 IAM User 删掉 / 让 STS Session 过期

效果是：

- 每个使用者拿到的都是**专属**凭据（用户名是 Vault 渲染出来的随机串）
- 每条凭据都**短寿命**：默认 lease TTL 之后自动作废
- 每次取用都被审计：谁用什么 token、在什么时间、铸出了哪个 IAM User

---

## 2. 路径布局：root 配置、Role 定义、凭据获取

启用 AWS 引擎后展开的路径分三层职责：

```
aws/                           ← 你 enable 时给的路径
├── config/
│   ├── root                   ← 管理员的 AWS Access Key（IAM 高权限种子）
│   ├── lease                  ← 默认 lease TTL / max TTL
│   └── rotate-root            ← 触发把 root key 在 AWS 上换一对新的
├── roles/<name>               ← Role 模板（credential_type + 权限边界）
├── creds/<role>               ← 应用来要 iam_user 凭据走这里
└── sts/<role>                 ← 应用来要 STS 三类凭据走这里
                                 （assumed_role / federation_token / session_token）
```

值得提前点出的几条规律：

- **`config/root` 是种子**：Vault 用它去调 AWS。这对 key 必须有创建
  IAM User / 调用 STS 的权限——本质上 Vault 拿到的是一份 IAM 管理员
  权限。后面 §6 会专门讲怎么给它"减负"
- **Role 是权限模板**：决定了应用最终拿到的临时凭据"能做什么"
- **`creds/` 与 `sts/` 是两条不同的入口**：长得很像，但对应的 AWS API
  完全不同——这是踩坑高发区，下一节展开

---

## 3. 四种 `credential_type`：调的是不同的 AWS API

写一条 Role 时必须指定 `credential_type`，它决定了 Vault 用哪个 AWS
API 去铸凭据，以及应用应该走 `creds/` 还是 `sts/` 取（[官方完整列表](https://developer.hashicorp.com/vault/docs/secrets/aws#aws-secrets-engine)）：

| `credential_type` | Vault 调的 AWS API | 凭据是否带 `session_token` | 应用读取路径 | 典型寿命 |
| --- | --- | --- | --- | --- |
| `iam_user` | `iam:CreateUser` + `iam:PutUserPolicy` + `iam:CreateAccessKey` | ❌（普通 AK/SK） | `aws/creds/<role>` | 受 Vault lease 控制（默认 768h，可配） |
| `assumed_role` | `sts:AssumeRole`（需要预先存在的目标 Role ARN） | ✅ | `aws/sts/<role>` | 由 STS 决定，最长 12 小时 |
| `federation_token` | `sts:GetFederationToken` | ✅ | `aws/sts/<role>` | 由 STS 决定，最长 36 小时 |
| `session_token` | `sts:GetSessionToken` | ✅ | `aws/sts/<role>` | 由 STS 决定，默认 1h、最长 36h |

> 注意：所有 STS 类型（`assumed_role` / `federation_token` /
> `session_token`）的凭据**一颁发即可用**，没有 `iam_user` 那个 5-10
> 秒的最终一致性窗口（参见 §3.1 的引用说明）。

### 3.1 `iam_user`：每次都"建一个真的 IAM 用户"

```bash
vault write aws/roles/s3-readonly \
  credential_type=iam_user \
  policy_document=-<<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": "s3:Get*", "Resource": "*" }]
}
EOF

vault read aws/creds/s3-readonly
```

输出：

```
Key                Value
---                -----
lease_id           aws/creds/s3-readonly/abc123...
lease_duration     768h
lease_renewable    true
access_key         AKIA....
secret_key         ....
session_token      <nil>
```

幕后 Vault 干了三件事：

1. 在 AWS 上 `CreateUser` 一个名字像 `vault-token-s3-readonly-1714125...`
   的真实 IAM User（用户名按 `username_template` 渲染，可自定义）
2. 把 `policy_document` 内联挂到这个用户身上
3. `CreateAccessKey` 拿到一对 AK/SK 返回给你，并把"这个 User 的删除时
   机"绑到 Vault Lease

`vault lease revoke <lease_id>` 时，Vault 反过来 `DeleteAccessKey` +
`DeleteUserPolicy` + `DeleteUser`——AWS 上不会留下任何痕迹（除了
CloudTrail 审计）。

> **注意 IAM 一致性窗口（官方文档明示）**：AWS 的 IAM 数据是跨服务
> [最终一致](https://developer.hashicorp.com/vault/docs/secrets/aws#usage)
> 的，刚 `CreateAccessKey` 拿到的 AK/SK 立刻去调其他 AWS 服务很可能
> 报 `InvalidClientTokenId`。HashiCorp 官方文档给的建议是：
> **在拿到凭据后强制 sleep 5-10 秒（甚至更久）再使用**，CI/CD 流水线
> 里这一行不能省。如果完全不想等，文档同时建议**改用 STS 类型**
> （`assumed_role` / `federation_token` / `session_token`）——STS 凭据
> 一颁发就立即可用，没有这个一致性窗口。

### 3.2 `assumed_role`：让 Vault 替你 AssumeRole

```bash
vault write aws/roles/s3-assume \
  credential_type=assumed_role \
  role_arns=arn:aws:iam::123456789012:role/app-s3-readonly

vault read aws/sts/s3-assume    # 注意路径是 sts/，不是 creds/
```

返回的是三件套（AK + SK + `session_token`），应用必须**同时**带上
`AWS_SESSION_TOKEN` 才能用。

适用场景：

- 已经有一套基于 IAM Role 的最小权限模型，不希望让 Vault 凭空创建新
  user
- 跨账号访问：root key 在账号 A、目标 Role ARN 在账号 B（账号 B 上要
  把账号 A 配到信任策略里）

> **路径区别决定一切**：`creds/<role>` 等同于"create-then-give-me-key"，
> `sts/<role>` 等同于"assume-and-give-me-session"。路径写错最直接的
> 表现是 `unsupported credential_type`。

### 3.3 `federation_token`：临时联邦身份

```bash
vault write aws/roles/s3-fed \
  credential_type=federation_token \
  policy_document=@s3-readonly.json

vault read aws/sts/s3-fed       # 注意：和 assumed_role 一样走 sts/
```

调的是 `sts:GetFederationToken`——这个 API 的特点是：

- **必须**用一个 IAM User 的长效凭据去调（即 Vault 的 `config/root`
  必须是 IAM User，不能是 Role / EC2 instance profile / WIF token）
- 返回的 session 权限是 **`config/root` 的策略 ∩ 你传入的
  `policy_document`** 的交集——所以即使你的 policy 写了 `s3:*`，最终
  能不能用还得看 root key 自己有没有 `s3:*`

实践中 `federation_token` 用得比 `iam_user` / `assumed_role` 都少——
因为它没法跨账号、又比 `assumed_role` 多一份"根 user 策略也得对"的
约束。你只需要知道它存在、并能在文档里认得出它即可。

### 3.4 `session_token`：直接给一份 root 凭据的"短寿命快照"

```bash
vault write aws/roles/temp_user credential_type=session_token
vault read aws/sts/temp_user
```

调的是 [`sts:GetSessionToken`](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetSessionToken.html)。
特别要点出的是 [官方文档中的警告](https://developer.hashicorp.com/vault/docs/secrets/aws#sts-session-tokens)：

> "STS session tokens inherit any and all permissions granted to the
> user configured in `aws/config/root`."

——`session_token` **不接受 `policy_document` / `policy_arns` 参数**，
拿到的临时凭据权限**等于** `config/root` 自己的全部权限。生产里几乎
不该用这种类型（除非你的 root key 已经被收窄到刚好够某个用途）。它
存在的主要意义是配合 IAM User 的 MFA：

```bash
vault write aws/roles/mfa_user \
  credential_type=session_token \
  mfa_serial_number="arn:aws:iam::ACCOUNT-ID:mfa/device-name"
vault read aws/creds/mfa_user mfa_code=123456
```

也就是"给一个开了 MFA 的 IAM User 通过 Vault 拿一份短期 session"。
课程后续的 WIF 章节会让这种用法进一步边缘化。

---

## 4. 端到端示例：从 enable 到 revoke

```bash
# 1. 启用并配置 root key（IAM 上要给这对 key 至少 IAMFullAccess）
vault secrets enable aws
vault write aws/config/root \
  access_key=AKIA... \
  secret_key=... \
  region=us-east-1

# 2. 调 Vault 默认 lease（不写就是 768h）
vault write aws/config/lease lease=1h lease_max=24h

# 3. 写一个 Role
vault write aws/roles/s3-readonly \
  credential_type=iam_user \
  policy_document=@s3-readonly.json

# 4. 应用拿凭据
vault read -format=json aws/creds/s3-readonly | tee /tmp/creds.json

# 5. 应用用完了，提前 revoke
vault lease revoke "$(jq -r .lease_id /tmp/creds.json)"
# 此时 AWS 上对应的 IAM User 已被删除，原 AK/SK 立即失效
```

`lease=1h` 之后，即使应用没主动 revoke，Vault 也会自动到点 `DeleteUser`。
这就是"动态机密 = 凭据生命周期 ≡ Lease 生命周期"的含义。

---

## 5. Role 进阶字段

### 5.1 `policy_arns` vs `policy_document`

| 字段 | 行为 |
| --- | --- |
| `policy_document` | 内联 IAM 策略 JSON，Vault 创建 User 时直接 attach |
| `policy_arns` | 一组**已存在**的 AWS 托管策略 ARN，把它们挂到新 User 上 |

两者可以**同时**用，最终生效的是并集。生产里常用 `policy_arns` 引用
组织里审计过的策略，避免每次写 policy 都要重新评审。

### 5.2 `username_template`

默认渲染出来类似 `vault-token-s3-readonly-1714...`，AWS 端 IAM User
名长度上限 64。如果业务上有命名规范、或者审计要求 user 名能反查 Vault
token，可以自定义模板：

```bash
vault write aws/roles/s3-readonly \
  credential_type=iam_user \
  policy_document=@policy.json \
  username_template='{{ printf "vault-%s-%s" .DisplayName .RoleName | truncate 60 }}'
```

模板可用变量包括 `.DisplayName`（Vault token 的 display name）、
`.RoleName`、`.PolicyName`、`unix_time`、`random N` 等——详见上游 API
文档。

### 5.3 `default_sts_ttl` / `max_sts_ttl`

只对 `assumed_role` 与 `federation_token` 生效，决定 Vault 调 STS 时
传入的 `DurationSeconds`。注意 STS 自身有硬上限：

- `assumed_role`：默认 1h，最大 12h（且 AWS 上目标 Role 的
  `MaxSessionDuration` 也得调够）
- `federation_token`：最大 36h

`iam_user` 的寿命**不受这俩字段控制**——它由 `aws/config/lease` 与
你的 Role 上的 `default_lease_ttl` / `max_lease_ttl` 决定。

---

## 6. 把 root key 当成首要风险来管

`aws/config/root` 那对 key 一旦泄露，攻击者能在 AWS 上随意造 IAM User、
把权限拉到管理员级别——所以这把"种子钥匙"反而比应用级凭据更敏感。

### 6.1 自动轮转 root

```bash
vault write -force aws/config/rotate-root
```

Vault 调 `iam:CreateAccessKey` 拿一对新 AK/SK、写回 `config/root`、
再 `DeleteAccessKey` 把旧的删掉。**操作完成后旧 AK/SK 立即失效，
任何外部备份都用不了**——所以做这步前确认没有别的系统在共享同一对
key。

> 配套的 `rotation_period` / `rotation_schedule`（Vault 1.18+）可以
> 让 Vault 按周期自动跑 `rotate-root`，不用人工 cron。

### 6.2 减少 root key 自身的权限面

文档里给出过 root key **最小权限**的参考策略——只允许它调 `iam:*User*`、
`iam:*AccessKey*`、`sts:*` 这几类相关 API。把这一组策略压成一个 IAM
Group 挂给"vault-root"专用 user，可以让"种子被泄露"的最坏情况受限到
"只能瞎建 User、不能直接读业务 bucket"。

### 6.3 只用 STS / 只用 IAM？

- **能用 `assumed_role` 就别用 `iam_user`**：不用 root key 持有 IAM
  写权限，最小化爆炸半径
- **真要用 `iam_user`，配额警告**：AWS 默认每个账号 IAM User 上限
  5000，如果你大规模用这种类型，得开支持工单提额；同时记得把 lease 调
  短，否则一堆死 user 占名额

---

## 7. Policy 路径速查

让应用按"只能取 `s3-readonly` 的凭据、不能动配置"原则授权——**注意
这里是 3 份相互独立的 policy，分别绑给 3 种不同的角色，不要把它们合
成一份**（合成一份就等于把所有权限都给了应用 token，恰好与"应用最小
权限"原则相反）：

```hcl
# ── policy: aws-app-s3-readonly ────────────────────────
# 绑给应用 token：只允许读取 s3-readonly 这一条 Role 的凭据
# 默认拒绝原则下，没列出的路径（roles/、config/、其他 creds/...）一律 403
path "aws/creds/s3-readonly" {
  capabilities = ["read"]
}
```

```hcl
# ── policy: aws-ops ────────────────────────
# 绑给运维 token：能管 Role 模板，但不能改 root key、不能直接取应用凭据
path "aws/roles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "aws/config/lease" {
  capabilities = ["create", "update", "read"]
}
```

```hcl
# ── policy: aws-security ────────────────────────
# 绑给安全 token：能触发 root key 自动轮转，但读不到 root key 内容、
# 也不能改 Role 模板（避免审计与运维混岗）
path "aws/config/rotate-root" {
  capabilities = ["update"]
}
```

如果某个应用真的需要 `assumed_role` 类型，就再写一份名字不同的 policy
（比如 `aws-app-s3-assume`），路径换成 `aws/sts/s3-assume`，绑给那
个应用的 token——**不要图省事在同一份 policy 里再加一个 `aws/sts/*`
通配**，否则该 token 又能拿到所有 STS Role 的凭据。

| 想做的事 | 路径 | capability |
| --- | --- | --- |
| 配置 root key | `aws/config/root` | `create` / `update` |
| 自动轮转 root | `aws/config/rotate-root` | `update` |
| 调 lease 默认值 | `aws/config/lease` | `create` / `update` |
| 写 / 读 Role | `aws/roles/<name>` | `create` / `read` / `update` / `delete` |
| 列 Role | `aws/roles/` | `list` |
| 取 `iam_user` 凭据 | `aws/creds/<role>` | `read` |
| 取 `assumed_role` / `federation_token` / `session_token` 凭据 | `aws/sts/<role>` | `read` |

> **常见踩坑**：把 `aws/creds/*` 都开放给应用，等于让它能拿到**所有**
> 已定义 Role 的凭据。生产里要按 Role 名精确写到 `aws/creds/<rolename>`
> 这一层。

---

## 8. 与其他章节的衔接

- **[2.3 Lease](/ch2-lease)**：动态机密的全部生命周期都是 Lease 的
  生命周期。`vault lease revoke` 在 AWS 引擎上就是真的去删 IAM User /
  让 STS 失效——把那一章的"租约即生命周期"理论落到了实处
- **[3.1 §3.4 move](/ch3-secrets-engines#34-move-原子重命名挂载路径)
  与 [5.7 Mount Migration](/ch5-mount-migration)**：AWS 引擎的所有
  `roles/<name>` 配置在 `move` 时**会**被一起搬走，但 Policy 里写死
  的 `aws/creds/...` 路径**不会**被改——和 KV v2 的 `data/...` 段一
  样要手动同步
- **2026 年课程后续的工作负载身份联邦（WIF）**：理想终态是连
  `aws/config/root` 都不再放静态 key，而是让 Vault 用 OIDC JWT 与
  AWS 联邦交换临时 STS——这是 plan.md 第 7 章的内容，本章先打好"动态
  机密 + Lease"的地基

---

## 9. 互动实验

本节配套了一个完整的 Killercoda 实验。考虑到学员手里没有真实的 AWS 账号
（免费层也要绑卡、且会真的产生 IAM 改动），实验环境用
[**MiniStack**](https://ministack.org/)——一个 MIT 协议、单端口 4566
的本地 AWS API 模拟器（LocalStack 的免费替代），让你**不花一分钱**就
能跑通：

- **Step 1**：启动 MiniStack、enable AWS 引擎、把 `config/root` 指向
  本地 4566 端点；体会 Vault 与 AWS 之间是普通 HTTP API 调用
- **Step 2**：写一个 `iam_user` Role，连续 `vault read aws/creds/`
  几次，去 MiniStack 端确认每次都真的多了一个 IAM User，然后
  `vault lease revoke` 看 user 立即消失
- **Step 3**：再写一个 `assumed_role` Role（需要先在 MiniStack 上手
  动建好目标 Role），从 `aws/sts/` 取出三件套凭据，用 `aws sts
  get-caller-identity` 验证身份切换
- **Step 4**：写一份"只允许 `aws/creds/<role>`、其它路径全拒"的
  Policy，故意触发几个 403，对照速查表把它修对

> **MiniStack 的限制**：`sts:GetFederationToken` API 没实现，所以
> `federation_token` 类型只能停留在文档介绍——本实验不演示。如果你
> 想看它在真 AWS 上的行为，把 `iam_endpoint` / `sts_endpoint` 删掉、
> 配上真账号的 root key 就能直接跑。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-aws" title="实验：AWS 机密引擎动态凭据全流程（MiniStack 模拟）" />
