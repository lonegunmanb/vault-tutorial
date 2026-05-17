---
order: 98
title: 9.7 Terraform 与 Vault Provider：用动态 AWS 凭据运行基础设施变更
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.7 Terraform 与 Vault Provider：用动态 AWS 凭据运行基础设施变更

> **核心结论**：Terraform 不应该长期持有一对写在本机环境变量里的 AWS access key。官方教程 [Inject secrets into Terraform using the Vault provider](https://developer.hashicorp.com/terraform/tutorials/secrets/secrets-vault) 演示的正是这条改造路径：先由 **Vault Admin** 用 Terraform 配好 Vault 的 AWS 机密引擎与一条受控 role，再由 **Terraform Operator** 在每次 `plan` / `apply` 时通过 Vault provider 现场领取一对短生命周期 AWS 凭据，并把这对临时凭据交给 AWS provider 使用。本节把官方教程重新组织成适合初学者理解的版本，并在动手实验中用 MiniStack 模拟 AWS，让你不需要真实 AWS 账号也能看到动态 IAM user 被创建、被用于创建 EC2 实例对象、再在租约到期后被 Vault 回收。

参考：
- 主参考：[Inject secrets into Terraform using the Vault provider — HashiCorp Tutorials](https://developer.hashicorp.com/terraform/tutorials/secrets/secrets-vault)
- 官方示例仓库：[hashicorp-education/learn-terraform-inject-secrets-aws-vault](https://github.com/hashicorp-education/learn-terraform-inject-secrets-aws-vault)
- [Terraform Vault Provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)
- [Vault AWS Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/aws)
- 已学衔接：[3.3 AWS 机密引擎](/ch3-aws)、[4.3 AWS 认证方法](/ch4-aws)、[2.3 租约（Lease）](/ch2-lease)、[9.1 安全加固基线](/ch9-production-hardening)

---

## 1. 这一节解决的问题：Terraform 手里的云凭据太长寿

很多团队刚开始用 Terraform 管 AWS 时，会把一对长期有效的 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` 发给每个开发者或 CI/CD runner。这样做很方便：Terraform AWS provider 看到环境变量，就能直接调 AWS API 创建 VPC、EC2、S3、IAM 等资源。

但安全问题也非常直接：

1. **凭据散落在很多机器上**：每个开发者笔记本、每条 CI pipeline、每台 bastion 都可能存着一对不同权限的长期 key；
2. **泄漏后的有效窗口很长**：一旦这对 key 被复制走，攻击者不需要再碰你的机器，只要 key 还没被人工禁用，就能继续调用 AWS；
3. **权限收紧很难统一**：你想让 Terraform Operator 不再有 `ec2:*` 权限，需要逐个找出所有被发出去的 key，再改 IAM policy 或轮换 key。

官方教程给出的方案是把这件事拆成两层：

- **少量长期 AWS 凭据只交给 Vault**，由 Vault AWS 机密引擎保管，用来创建短期 IAM user / access key；
- **Terraform Operator 不再直接持有长期 AWS 凭据**，它只持有访问 Vault 的能力，在每次运行时向 Vault 领一对临时 AWS key。

这就把安全模型从「谁拿到了长期 AWS key，谁就一直有云权限」改成了「谁能通过 Vault policy 访问某条 role，谁才能在当前这次 Terraform 运行里拿到一对短期、受限、可回收的 AWS key」。

---

## 2. 官方教程的两个角色：Vault Admin 与 Terraform Operator

官方教程最值得学习的地方，不是某个单独的 Terraform resource，而是它把职责边界分成了两个工作区。

### 2.1 Vault Admin 工作区：配置凭据发行规则

第一个工作区叫 `vault-admin-workspace`。它代表平台或安全团队，负责把「谁能签发 AWS 凭据、签出来的凭据能做什么」写进 Vault。

这个工作区做五件事：

1. 用 AWS provider 创建一个 IAM user，作为 **Vault AWS secrets engine 自己调用 AWS API 的 root credential**；
2. 给这个 IAM user 挂一条允许管理 IAM 的 policy，这样 Vault 后续才能创建和删除动态 IAM user；
3. 用 Vault provider 创建 `vault_aws_secret_backend`，也就是把 AWS secrets engine 挂到 Vault 某个路径下；
4. 把第 1 步生成的 access key / secret key 写入这个 secrets engine；
5. 创建 `vault_aws_secret_backend_role`，定义 Terraform Operator 未来拿到的动态 IAM user 具备哪些 AWS 权限。

官方示例里的 role 使用 `credential_type = "iam_user"`，也就是说 Vault 每次被请求 `.../creds/<role>` 时，都会去 AWS IAM 创建一个真实的 IAM user，再给它创建 access key。role 的 `policy_document` 初始允许 `iam:*` 与 `ec2:*`，因此 Operator 工作区可以用这对动态凭据创建 EC2 实例。

请注意这条边界：**Admin 工作区负责配置发行规则，不负责创建业务基础设施**。它创建的是「凭据工厂」。

### 2.2 Terraform Operator 工作区：领取短期凭据并创建资源

第二个工作区叫 `operator-workspace`。它代表每天运行 Terraform 的开发者或自动化流水线。

这个工作区的核心链路是：

1. 用 `terraform_remote_state` 读取 Admin 工作区输出的 `backend` 与 `role`；
2. 用 Vault provider 的 `vault_aws_access_credentials` data source 请求这条 role；
3. Vault AWS secrets engine 创建一对短期 AWS access key / secret key；
4. Terraform AWS provider 使用这对短期 key 初始化；
5. AWS provider 创建一台 EC2 实例。

这一步最重要的观察是：**AWS provider 使用的 access key 不是人提前发给 Operator 的，而是 Terraform 在运行中从 Vault 取回来的**。每次 `plan` 或 `apply` 都可以对应一对新的短期凭据。

### 2.3 第三幕：Admin 收紧 role，Operator 立刻失去 EC2 权限

官方教程的最后一段非常关键：Vault Admin 回到 `vault-admin-workspace`，把 role 的 `policy_document` 里 `ec2:*` 移除，只保留 `iam:*`。然后 Terraform Operator 再运行 `terraform plan`，会因为没有 EC2 权限而失败。

这说明权限边界已经回到了 Vault role 这一处集中配置：

- 不需要逐个找开发者机器上的长期 key；
- 不需要让 Operator 知道任何新的 AWS secret；
- 修改 Vault role 后，下一次动态凭据签发就会自动采用新的权限边界。

---

## 3. 运行时到底发生了什么

把官方教程的两个工作区串起来，一次完整的 Terraform apply 可以理解成下面这条流水线：

```text
Vault Admin Terraform
  │
  │ ① 创建 AWS IAM user，作为 Vault secrets engine 的 root credential
  │ ② 在 Vault 中挂载 AWS secrets engine，并创建 role
  ▼
Vault: dynamic-aws-creds-vault-path/roles/dynamic-aws-creds-vault-role

Terraform Operator
  │
  │ ③ data.terraform_remote_state 读出 backend 与 role
  │ ④ Vault data source 请求短期 AWS 凭据
  ▼
Vault AWS secrets engine
  │
  │ ⑤ 调 AWS IAM 创建临时 IAM user + access key，绑定 lease
  ▼
AWS provider
  │
  │ ⑥ 用临时 key 创建 EC2 instance
  ▼
AWS EC2
```

这里有两个初学者很容易混淆的点。

**第一，Vault provider 和 AWS provider 是两条不同的认证链。** Vault provider 用 `VAULT_ADDR` / `VAULT_TOKEN` 连接 Vault；AWS provider 用 Vault data source 返回的 `access_key` 与 `secret_key` 连接 AWS。也就是说，Operator 仍然需要有一枚能访问 Vault 的 token，但不再需要长期 AWS key。

**第二，`terraform_remote_state` 不是把 Admin 权限交给 Operator。** Operator 只读取 Admin 工作区输出的两个普通字符串：AWS secrets engine 的挂载路径和 role 名。真正能不能拿凭据，仍然由 Operator 当前使用的 Vault token 是否允许访问 `backend/creds/role` 决定。官方教程为了聚焦主线使用 dev 模式 root token，本课程实验也保持这个简化；生产环境必须给 Operator 单独发一枚最小权限 Vault token，只允许读取那条 `creds` 路径。

---

## 4. 两个 TTL 场景：先让它失败，再只改 Vault 接入让它续起来

官方教程把 AWS secrets engine 的 `default_lease_ttl_seconds` 设为 `120`。这只是一个**演示默认值**：足够短，方便你在教程里很快看到 Vault 到期回收动态 IAM user；也足够危险，方便你意识到「短 TTL」会和 Terraform 的运行时间发生冲突。它不代表生产环境里所有 Terraform apply 都应该共用 120 秒。

本课程实验会把这个问题拆成两幕，而且两幕使用**同一份 Terraform 代码**：第一幕直连 Vault，固定 120 秒 TTL，短 apply 成功、长 apply 失败；第二幕 Terraform 文件一行不改，只把 Vault 接入方式换成 Vault Proxy，让 Proxy 托管动态 lease 的续期，同一条长 apply 成功。

有一个本地模拟 AWS 的适配点要提前说明：官方教程的 Operator 工作区使用 `vault_aws_access_credentials` data source；本实验读取的是同一个 `backend/creds/role` 路径，但用通用的 `vault_generic_secret` data source。原因是当前 Vault provider 的 `vault_aws_access_credentials` 会额外向真实 AWS IAM 做凭据有效性校验，却没有本地 IAM endpoint 参数；`vault_generic_secret` 不做这一步校验，仍然能拿到 Vault AWS secrets engine 签发的 `access_key`、`secret_key`、`lease_id`、`lease_duration` 与 `lease_renewable`。

### 4.1 第一幕：直连 Vault，短 apply 成功、长 apply 失败

先把最基本的边界说清楚：`vault_aws_access_credentials` 读取 AWS secrets engine 时会拿到一份带 lease 的动态 AWS 凭据；但 **Terraform Vault provider 自己不会替这份 lease 做续期**。官方 provider 文档也明确提醒：当你把这个 data source 的输出交给 AWS provider 使用时，这组凭据无法由 Terraform 自动续租，因此 lease 必须长到足以覆盖这次 Terraform 运行。也就是说，如果你只按官方教程的最小形态直连 Vault：

```text
Terraform Vault provider ──▶ Vault ──▶ AWS dynamic credentials ──▶ Terraform AWS provider
```

那么 Terraform 的确认等待时间、`plan` / `apply` 执行时间、网络重试时间，都必须落在这份 lease 的有效窗口内。否则 AWS provider 后续调用就会因为凭据已被 Vault 回收而失败。`-auto-approve` 只能减少「人停在确认提示上」的等待时间，不能解决大型 apply 本身跑很久的问题。

实验里会用一个 `apply_delay` 变量和 `time_sleep` 资源模拟 apply 中间的长耗时操作。`apply_delay=0s` 时，Terraform 很快创建 MiniStack EC2 instance，120 秒 TTL 足够用；`apply_delay=150s` 时，Terraform 在拿到 Vault 动态 AWS key 之后故意等待 150 秒，再去调用 EC2 API。这时 Vault 已经回收了动态 IAM user，AWS provider 手里的 access key 变成了失效凭据，长 apply 就会挂掉。

为了让这个失败在交互式实验里及时出现，Operator 工作区还把 Terraform AWS provider 的 `max_retries` 设为 `1`，并在 shell 环境里设置 `AWS_MAX_ATTEMPTS=1`。这是课堂节奏调整：AWS provider 默认会对 AWS API 调用做较多重试，过期 key 被 MiniStack 拒绝后如果继续沿用默认值，学员可能会在 `DescribeAvailabilityZones` 上多等很久。

### 4.2 第二幕：Terraform 代码不改，只改 Vault 接入配置，由 Proxy 续租

第二幕的关键是：**不改 Terraform 文件**。仍然是同一个读取 Vault AWS `creds` 路径的 data source，仍然是同一个 AWS provider 配置，仍然跑 `apply_delay=150s` 的长 apply。唯一变化是 Terraform 不再直连 Vault Server，而是把 `VAULT_ADDR` 指向本机 Vault Proxy listener。

Vault Proxy 通过 Auto-auth 先拿到一枚它自己管理的 Vault token；Terraform 运行时用这枚 token 通过 Proxy 请求 AWS 动态凭据。由于这次 leased secret 创建请求经过 Proxy，并且使用的是 Proxy 已经管理的 token，Proxy 会缓存这份动态 AWS 凭据响应，并在后台通过 Vault renewer 替它续期。

这条生产形态可以理解成：

```text
Terraform Vault provider ──▶ Vault Proxy ──▶ Vault ──▶ AWS dynamic credentials
                                │
                                └── 后台续期 token 与 dynamic secret lease
```

对于本教程使用的 `iam_user` 类型动态凭据，续期的含义是「Vault 延后删除这名动态 IAM user / access key」。Terraform AWS provider 手里的 access key 字符串不变，但它背后的 IAM user 不会在原始 120 秒到点时被 Vault 删除，所以 150 秒后的 EC2 API 调用仍然能成功。

这就是本节实验真正要你看到的对比：

| 场景 | Terraform 代码 | Vault 接入方式 | 150 秒长 apply 结果 |
| --- | --- | --- | --- |
| 固定 120 秒 TTL | 不变 | Terraform provider 直连 Vault Server | 失败：动态 IAM user 到期被回收 |
| Proxy 托管续期 | 不变 | Terraform provider 连接 Vault Proxy listener | 成功：Proxy 在后台续期 lease |

### 4.3 生产取舍：续租不是把 TTL 问题抹掉

生产里通常有三层做法，而不是把所有工作负载都塞进同一个 TTL。

**第一层：按 Terraform 运行类型拆 role / backend 的 TTL。** 小型、频繁、低风险的变更可以用更短的默认 TTL；大型网络、集群、数据库迁移这类长 apply 应该使用更长的 `default_lease_ttl_seconds` 与 `max_lease_ttl_seconds`，或者拆成单独的 Vault role / 单独的 Terraform workspace。经验上不要凭感觉拍脑袋，而是看 CI 历史里 `plan` + `apply` 的 P95 / P99 时长，再加上合理的云 API 重试缓冲。

**第二层：把大 apply 拆小。** 如果一次 Terraform run 需要几十分钟甚至更久，单纯把 TTL 拉长会扩大泄漏窗口。更好的做法通常是把基础网络、共享安全组、数据层、应用层拆成多个 state / workspace，让每次 apply 的 blast radius 与凭据有效期都更可控。

**第三层：让 Vault Agent 或 Vault Proxy 托管动态租约续期。** 本节实验选择 Vault Proxy，因为这是现代 Vault 工具链里更明确的 API proxy 角色；Vault Agent 在动态 token / lease 缓存续期上也具备同类能力，但 Agent 的旧 API proxy 职责已经不再是推荐主线。使用哪一个，取决于你在第 5.6、7.2、7.3 节里学到的接入形态选型。

它的边界也必须讲清楚：续期不能突破 Vault role / mount 的 max TTL；Agent / Proxy 进程退出后续期会停止；如果有人绕过 Agent / Proxy 直接 revoke lease，它们可能只剩一条陈旧缓存；而且并不是所有 AWS credential type 都适合被这样续期。比如基于 AWS STS 的 `assumed_role` / `federation_token` 本身有 AWS 侧的到期时间，不能像 `iam_user` 那样简单地「延后删除 IAM user」。所以，Agent / Proxy 续期是生产里很有价值的方案，但它不是把 TTL 问题抹掉，而是把「Terraform provider 不续期」这件事交给一个明确的本地守护进程来托管。

本课程实验仍然保留官方教程的 120 秒 TTL，并使用 `terraform apply -auto-approve`，目的不是推荐生产也这么配，而是让初学者在几分钟内看到两件事：固定 TTL 确实会让长 apply 失败；同一份 Terraform 代码在接入 Vault Proxy 后，又能因为动态 lease 续期而跑通。

---

## 5. MiniStack 版实验与官方教程的差异

官方教程使用真实 AWS 账号，并要求你在 AWS Console 里观察 IAM user 与 EC2 instance。本课程坚持零真实云成本，所以用 MiniStack 模拟 AWS IAM / STS / EC2。为了让实验既能本地跑通，又不偏离官方教程的主线，需要做几处替换。

| 官方教程 | 本课程实验 |
| --- | --- |
| 真实 AWS IAM / STS / EC2 | MiniStack `127.0.0.1:4566` 模拟 IAM / STS / EC2 |
| AWS Console 里看动态 IAM user | `awslocal iam list-users` 查看动态 IAM user |
| AWS Console 里看 EC2 实例 | `awslocal ec2 describe-instances` 查看本地模拟的 instance 对象 |
| `data.aws_ami.ubuntu` 查询 Canonical 公共 AMI | MiniStack 没有真实公共 AMI 目录，实验使用固定的模拟 AMI ID，并用 `data.aws_availability_zones` 保留 plan 阶段的 EC2 API 检查 |
| 手动 `terraform apply` 后输入 `yes` | 实验用 `-auto-approve`，避免 120 秒 TTL 被人工等待耗尽 |
| AWS provider 默认重试 | 实验设置 `max_retries = 1` / `AWS_MAX_ATTEMPTS=1`，避免预期失败拖太久 |
| 真实 AWS 计费风险 | 无真实 AWS 账号，无云费用 |

除此之外，核心结构保持一致：仍然是两个 Terraform 工作区，仍然由 Admin 工作区创建 Vault AWS secrets engine 与 role，仍然由 Operator 工作区读取同一条 Vault AWS `creds` 路径领取动态 AWS key，仍然用移除 `ec2:*` 来验证权限收紧。

实验里会以 `ENFORCE_IAM=1` 启动 MiniStack，并使用镜像 `ghcr.io/lonegunmanb/ministack:sha-41865eb-full`（按提交 SHA 固定，保证教程可复现）。这样当 Admin 移除 `ec2:*` 后，Operator 再次运行 plan 时会看到与真实 AWS 类似的未授权错误；当 Vault 回收动态 IAM user 后，旧 access key 再调用 EC2 也会收到 `InvalidClientTokenId`，而不是被本地模拟器「宽松放行」。

---

## 6. Terraform state 的安全边界

官方教程聚焦「如何把 AWS 凭据动态注入 Terraform」，但初学者必须顺手理解另一个安全事实：**Terraform state 会记录很多敏感信息**。

在 Admin 工作区里，`vault_aws_secret_backend` 会把写入 Vault 的 AWS root credential 作为资源配置的一部分参与 Terraform 状态管理。较新的 Vault provider 提供了 write-only secret key 这类更安全的能力，但官方教程使用的是经典写法；本课程实验为了与官方教程保持一致，也保留这条主线。

这意味着生产中至少要做到：

1. 不要把 `terraform.tfstate` 提交到 Git；
2. 使用带加密、访问控制和审计能力的远程 state backend；
3. 严格限制谁能读取 Admin 工作区 state；
4. 给 Operator 使用最小权限 Vault token，而不是 root token；
5. 把动态 AWS 凭据 TTL 设到能完成工作但不过长的范围。

请把这句话记住：**Vault 减少的是 Terraform 运行时长期 AWS key 的分发，不是让 Terraform state 自动变得无敏感信息**。这两件事不能混为一谈。

---

## 7. 本节小结

把官方教程压缩成一份认知清单，可以得到七条：

1. **不要把长期 AWS key 发给每个 Terraform Operator**；
2. **让 Vault AWS secrets engine 成为短期 AWS 凭据的发行方**；
3. **Admin 工作区配置「凭据工厂」**：IAM root credential、Vault AWS backend、Vault role；
4. **Operator 工作区只读取动态凭据**：`terraform_remote_state` 找到 role，再读取 Vault AWS `creds` 路径领取 key；
5. **TTL 要按运行形态设计**：直连 Vault 时 Terraform provider 不续租；长 apply 要么拆小 / 调长 TTL，要么让 Agent / Proxy 托管动态 lease 续期；
6. **权限收紧集中在 Vault role**：移除 `ec2:*` 后，下一次动态凭据立即失去 EC2 能力；
7. **state 仍然敏感**：动态凭据不是忽略 Terraform state 安全的理由。

掌握这些之后，下面的实验会让你在本地完整跑一遍官方教程的主线：用 Terraform 配 Vault，再让 Terraform 通过 Vault 临时拿 AWS 凭据去改基础设施。

---

## 8. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Ubuntu 主机上启动 dev 模式 Vault 与 MiniStack，使用两个 Terraform 工作区复现官方教程。

1. **Vault Admin 工作区**：用 Terraform 在 MiniStack 上创建 Vault 专用 IAM user，把它的 access key 写入 Vault AWS secrets engine，并创建一条能签发 `iam:*` / `ec2:*` 动态凭据的 role；
2. **演示一：固定 120 秒 TTL**：同一份 Operator Terraform 代码，`apply_delay=0s` 的短 apply 成功，`apply_delay=150s` 的长 apply 失败；
3. **演示二：Proxy 自动续期**：Terraform 文件一行不改，只启动 Vault Proxy 并把 Terraform 的 Vault 请求改走 Proxy listener，同一条 `apply_delay=150s` 长 apply 成功；
4. **权限收紧**：Admin 移除 role 中的 `ec2:*`，Operator 再次 `terraform plan`，看到 EC2 权限不足导致失败。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-terraform-vault-aws" title="实验：用 Vault 动态 AWS 凭据运行 Terraform（MiniStack 版）" />