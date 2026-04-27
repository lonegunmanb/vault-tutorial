---
order: 35
title: 3.5 SSH 机密引擎：从静态密钥到 CA 签发与一次性密码
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.5 SSH 机密引擎：从静态密钥到 CA 签发与一次性密码

> **核心结论**：Vault 的 SSH 机密引擎不解决"在哪存 SSH 私钥"，它解决
> 的是"如何让目标主机**不再需要保管谁的公钥**"。两种现存模式各走一
> 条路：**Signed Certificates (CA 模式)** 让目标主机只信任一个 SSH
> CA 公钥，所有人的临时短期证书都由 Vault 即时签发；**OTP (One-Time
> Password) 模式**让目标主机装一个小 helper（`vault-ssh-helper`）
> 接管 PAM 验证流，每次登录的密码都是 Vault 现场颁发、用完即焚的一
> 次性令牌。**老的 Dynamic Keys 模式自 Vault 1.13 起已彻底移除**，
> 不再有第三种选项。本章把这两条路的架构、配置链路、彼此取舍一次讲
> 透，并在动手实验里全部用容器作为目标主机，**完全不污染宿主机**。

参考：
- [SSH Secrets Engine 总览](https://developer.hashicorp.com/vault/docs/secrets/ssh)
- [Signed SSH Certificates](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates)
- [One-Time SSH Passwords](https://developer.hashicorp.com/vault/docs/secrets/ssh/one-time-ssh-passwords)

---

## 1. SSH 引擎在 Vault 路由表里的位置

回到 [3.1 章](/ch3-secrets-engines)那张"机密引擎 = 挂在路由表上的插
件"心智模型：SSH 引擎跟 KV、AWS、PKI 一样，都是 `vault secrets
enable -path=<挂载点> ssh` 挂出来的一个普通插件。它的两条根本特征
（区别于其它引擎）是：

1. **生成的产物不是"机密字符串"，而是"登录凭证"**——一份签好名的 SSH
   证书，或一个写进了某台目标主机 PAM 流里的一次性密码。这两种产物
   都不能被 Vault 自己使用，需要客户端拿出去配合 OpenSSH / PAM 真
   的发起一次 SSH 登录。
2. **必须有"目标主机端的配合"**——CA 模式要在 sshd 里配一行
   `TrustedUserCAKeys`，OTP 模式要在主机上装 `vault-ssh-helper` 并
   修改 PAM。这跟 KV / Cubbyhole 那种"Vault 自给自足"的引擎完全不
   同：SSH 引擎是**横跨 Vault 与目标主机两端**的协议。

> 一个常见的入门误区：以为 SSH 引擎是"Vault 帮我保管 SSH 私钥的地
> 方"——**不是**。私钥要么仍由用户持有（CA 模式：客户端有 id_rsa，
> Vault 只签 id_rsa.pub），要么压根就不需要密钥（OTP 模式：用一次
> 性密码登录）。Vault 永远不持有用户的 SSH 私钥。

---

## 2. 三种历史模式与 1.13 后的现状

[官方 SSH 文档首页](https://developer.hashicorp.com/vault/docs/secrets/ssh)
提到过历史上 SSH 引擎有三种 `key_type`：

| key_type | 状态 | 简介 |
| :--- | :--- | :--- |
| `ca` | ✅ **当前主流**，本章 §3–§5 | Vault 当 SSH CA，签发短期证书。目标主机只需信任 CA 公钥，零账户态 |
| `otp` | ✅ **仍受支持**，本章 §6 | 目标主机装 vault-ssh-helper + PAM，每次登录用 Vault 颁发的一次性密码 |
| `dynamic` | ❌ **1.13 起移除** | 让 Vault SSH 进目标主机临时创建一个 Linux 用户、写入临时公钥、登录后销毁。维护负担极重，已被 CA 模式完全取代 |

> 如果你在老博客或老教程里看到 `vault write ssh/keys/...` 这种命令，
> 它讲的就是已经被移除的 dynamic 模式——直接跳过即可。

**现代选项就两个**：CA 与 OTP。它们在架构、运维负担、信任根上是两
条互不重叠的路径，§7 会做一张完整对比表。

---

## 3. CA 模式架构：把"信任公钥列表"换成"信任一把 CA"

CA 模式借用了 OpenSSH 自身就支持的 SSH Certificate 机制
（OpenSSH 5.4+，2010 年就有了，跟 Vault 无关）。它的模型只有四个
角色：

```
                  ┌──────────────────┐
                  │   Vault SSH CA    │
                  │  (私钥不出 Vault) │
                  └────────┬──────────┘
                           │ 签发 5 分钟有效的证书
                           ▼
   客户端公钥 (id_rsa.pub)  ────────►  签好名的 cert (id_rsa-cert.pub)
                           │
                           │ ssh -i id_rsa-cert.pub -i id_rsa user@host
                           ▼
                  ┌──────────────────┐
                  │   目标主机 sshd   │
                  │ TrustedUserCAKeys │
                  │   = CA 公钥       │
                  └──────────────────┘
```

最关键的一处认知翻转：

> **目标主机的 `~/.ssh/authorized_keys` 可以彻底空着**。它不再需要
> 保管"谁是合法用户的公钥"，只需要在 sshd 配置里写一行
> `TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem`，剩下"谁能
> 登"全部由 Vault 在签发证书时通过 `principals` 字段决定。

这一翻转带来的真实效果是：

- **加新用户不用碰目标主机**——只要新用户在 Vault 里有合适的
  Policy 能调签发端点，他就能登。运维不再需要在几百台机器上同步
  `authorized_keys`
- **撤权也不用碰目标主机**——删掉 Vault 里的 Policy / Token 就行；
  顶多再等当前最大 TTL（一般 5 分钟）即可彻底失效
- **审计中心化**——谁、什么时候、为登哪台机器签了证书，全部在
  Vault 审计日志里有一条结构化记录

---

## 4. CA 模式服务端配置：三步成型

完整链路的服务端（= Vault 这一侧）只需要三步，每一步只对应 1–2 行
命令。本章实验 Step 1–2 会逐条跑。

### 4.1 启用引擎，挂个路径

```bash
vault secrets enable -path=ssh-client-signer ssh
```

> 路径名按惯例叫 `ssh-client-signer`（这是 Vault 文档使用的命名约
> 定）。如果一个 Vault 里同时管理多个互不信任的环境（例如生产 vs
> 开发），可以挂多个：`ssh-prod-signer`、`ssh-dev-signer`，每个有
> 自己的 CA。

### 4.2 让引擎自己生成 CA 私钥

```bash
vault write ssh-client-signer/config/ca generate_signing_key=true
```

返回里有 `public_key` 字段——**这把公钥就是接下来要分发到所有目标
主机 sshd 配置里的那把**。私钥不出 Vault，连 root 也不能 export。

> 也可以用 `generate_signing_key=false`，自己提供一对密钥
> （`private_key=...` + `public_key=...`）——这条路径主要用于"已
> 经有了一把 SSH CA、想接进 Vault 管"的场景；新部署直接让 Vault 生
> 就行。

### 4.3 创建一个签发 Role

```bash
vault write ssh-client-signer/roles/my-role -<<EOF
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "allowed_extensions": "permit-pty,permit-port-forwarding",
  "default_extensions": { "permit-pty": "" },
  "default_user": "ubuntu",
  "ttl": "5m0s"
}
EOF
```

每个字段的含义：

| 字段 | 含义 | 不写会怎样 |
| :--- | :--- | :--- |
| `key_type=ca` | 声明这是个 CA 签发 role（区别于 `otp`） | role 创建会被引擎拒收 |
| `allow_user_certificates=true` | 允许签**用户证书**（用来登录） | 默认 false，签出来会是空 cert |
| `allowed_users="*"` | 允许在签发请求里指定任何 Linux 用户名 | 默认 `""`，只能签 `default_user` 那一个 |
| `default_extensions={permit-pty:""}` | 证书自带 `permit-pty` 扩展 | sshd 给你登进去但**没有交互式 shell**——所有命令立刻挂掉 |
| `default_user="ubuntu"` | 没显式传 `valid_principals` 时，默认作为 principal 写入证书 | 触发 OpenSSH 那个出名的 `name is not a listed principal` 报错 |
| `ttl="5m0s"` | 证书有效期 5 分钟 | 默认很长（几十分钟），违反"短证书"原则 |

> `default_user` + `default_extensions.permit-pty` 这两个字段是新手
> 最容易漏的，[官方 troubleshooting](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates#troubleshooting)
> 单独列了一节。本章实验 Step 2 会**故意先不写它们**，让你亲眼看到
> 这两个错误是什么样子，再加上去。

---

## 5. CA 模式客户端流程：sign → ssh

### 5.1 先把 SSH 登录的"三件套"理清楚

CA 模式下，客户端 SSH 一次需要**三样东西**同时在场，缺一不可：

| 文件 | 谁生成的 | 作用 |
| :--- | :--- | :--- |
| `~/.ssh/id_rsa` | 客户端自己 `ssh-keygen` 生成的**私钥**（机密，永远不外传） | ssh 用它来"签字"证明"我就是这把公钥的主人" |
| `~/.ssh/id_rsa.pub` | 上面那条命令同时生成的**公钥**（可公开） | 拿去给 Vault 签——签完就成了下一行的"证书" |
| `~/.ssh/id_rsa-cert.pub` | **Vault 签发的证书**（公开但 5 分钟过期） | 告诉 sshd："这把公钥已经被你信任的 CA 背书过，且我有权登录 ubuntu 用户" |

类比一张表能更直观：

| SSH 文件 | 类比 |
| :--- | :--- |
| `id_rsa`（私钥） | 你的**身份证原件** + 签名笔——只在自己手里 |
| `id_rsa.pub`（公钥） | 身份证上**那张照片**——给谁看都行 |
| `id_rsa-cert.pub`（证书） | 一张**贴着这张照片、由派出所盖章、5 分钟内有效的临时通行证**——派出所就是 Vault CA |

> 关键一点：**Vault 从头到尾都没碰过你的私钥**。你拿公钥去签，签出
> 来的证书也是公开的——私钥仍然安静地躺在你 `~/.ssh/id_rsa` 里，没
> 离开过本机。这是 CA 模式安全性的基石。

### 5.2 签发：让 Vault 给公钥"盖章"

```bash
vault write -field=signed_key ssh-client-signer/sign/my-role \
    public_key=@$HOME/.ssh/id_rsa.pub > $HOME/.ssh/id_rsa-cert.pub
```

逐段拆解这条命令：

- `vault write ssh-client-signer/sign/my-role`：调用 Vault 的"签发"
  端点，使用我们在 §4.3 创建的 `my-role`
- `public_key=@$HOME/.ssh/id_rsa.pub`：把客户端公钥**作为请求体**
  发上去（`@文件名` 是 Vault CLI 的语法糖，等价于"读这个文件的内容
  当参数")
- `-field=signed_key`：Vault 返回是个 JSON，里面有很多字段；我们只
  要其中的 `signed_key` 字段（也就是签好的证书内容）
- `> $HOME/.ssh/id_rsa-cert.pub`：把这串证书内容写到一个文件里

签完之后用 `cat` 看一眼，会发现它就是一行 base64 字符串——本质上
就是"你的公钥 + Vault 的签名 + principals 列表 + 过期时间"打包在
一起。

### 5.3 登录：为什么 ssh 命令看起来"少了点东西"

```bash
ssh -i $HOME/.ssh/id_rsa ubuntu@target-host
```

第一次看见会觉得奇怪——**命令里只指定了私钥 `id_rsa`，证书
`id_rsa-cert.pub` 在哪儿？**

答案：**OpenSSH 自动找到了它**。OpenSSH 客户端有一条硬编码规则：

> 当用 `-i <某个私钥文件>` 时，如果它**同目录**下有一个**同名加
> `-cert.pub` 后缀**的文件，自动把它当作配套证书带上。

也就是说：

```
-i ~/.ssh/id_rsa     ← 你只写了这个
                     ↓ ssh 客户端自动顺手挂上：
                     ~/.ssh/id_rsa-cert.pub
```

所以 §5.2 的输出文件**必须**叫 `id_rsa-cert.pub`，命名错了（比如
存成 `mycert.pub`）这条自动机制就失效，登录会失败。

### 5.4 不想用"自动配对"？也行——显式两个 -i

如果你不愿意把证书放在 `~/.ssh/` 下（比如想存到别的目录、不想用
`-cert.pub` 这个固定后缀），就**显式两个 `-i`**，把证书路径明确告
诉 ssh：

```bash
ssh -i ~/some-dir/mycert.pub \
    -i ~/.ssh/id_rsa \
    ubuntu@target-host
```

两种写法的最终效果完全一样——sshd 都收到"私钥签的字 + 证书"两份
材料，验证过程也一模一样。**自动配对只是"少打一个 `-i`"的便利**，
不是必须的。

### 5.5 还有一种"反向证书"：Host Key Signing（可选）

对应 [§Host Key Signing](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates#host-key-signing)。
默认情况下 SSH 客户端是用 `~/.ssh/known_hosts` 来认目标主机指纹的
——第一次连过去会跳出 "fingerprint is xxx, are you sure?" 那个对
话。这条路在多服务器、自动伸缩集群里很难维护。

让 Vault 也给**目标主机的 host key** 签一份证书，客户端就只需在
`known_hosts` 里写一行 `@cert-authority *.example.com <ssh CA pub
key>`，所有这个域下的主机以后第一次连都自动信任。

这条机制本章实验 Step 3 跑一次，但**不是必修**——它在大量小型场景下
显得过度，先理解 §3–§5 的"客户端证书"再说。

---

## 6. OTP 模式：把 SSH 密码托管给 Vault

### 6.1 什么叫 OTP？

OTP 是 **One-Time Password**（一次性密码）的缩写，指的是这样一类
密码：

- **只能用一次**——验证通过后立刻作废，第二次输入会被拒；
- **寿命极短**——通常是几分钟内的"一阵子"，不是永久有效；
- **不需要用户记忆**——它不是你设的密码，而是系统**临时生成、临时
  发给你**的一段长字符串。

> 你日常生活里见过的 OTP 例子：网银登录的"短信验证码"、Google
> Authenticator 每 30 秒变一次的 6 位数、银行 U 盾上滚动跳的那串
> 数字。**用完就废**是它们的共同点。

放到 SSH 这个场景里：传统 SSH 密码（即写死在 `/etc/shadow` 里那种）
是**用户设置的、长期不变的固定字符串**——一旦泄漏，攻击者可以反复
登录直到密码被改。OTP 模式把这件事翻过来：

> **每次** SSH 登录前都先去问 Vault 要一个全新的密码，登完这个密码
> 就被 Vault 物理删除——下次再登要重新申请。**密码即用即焚，永远
> 不在硬盘上停留**。

这就是 OTP 模式相比传统密码登录的核心安全升级。下面看 Vault 是怎么
把这件事工程化实现的。

### 6.2 OTP 适用的场景

CA 模式的前提是"目标主机的 sshd 我能改配置（加 `TrustedUserCAKeys`
那行）"。如果目标主机出于某种原因**只支持密码认证、不能用证书 / 公
钥**——比如：

- 老旧设备的 SSH 实现连 SSH Certificate 都不支持
- 合规要求"必须有一个可输入的密码"
- 跨厂商混合环境，每家产品的公钥配置方式都不一样

——CA 模式就用不上。这时候就轮到 OTP 模式：**目标主机依然走标准的
"用户名 + 密码"登录流程**（这是几乎所有 SSH 实现都支持的最低公分
母），但密码不再是固定的，而是 Vault 现场颁发的一次性令牌。

### 6.3 OTP 模式的端到端流程

[官方 OTP 文档](https://developer.hashicorp.com/vault/docs/secrets/ssh/one-time-ssh-passwords)
给的架构如下：

```
   1. 客户端：vault write ssh/creds/otp_key_role ip=<target>
                    │
                    ▼
              Vault 颁发一次性密码 (一个长字符串)
                    │
                    ▼
   2. 客户端：ssh user@target  → sshd 走 PAM 流
                    │
                    ▼
   3. 目标主机 PAM (auth) → 调用 vault-ssh-helper
                    │
                    ▼
   4. vault-ssh-helper 拿用户输入的密码去问 Vault：
        "这个 OTP 是你刚发出来给 user@target 的吗？"
                    │
                    ▼
              Vault 验证 + 销毁这个 OTP
                    │
                    ▼
   5. helper 返回 PAM_SUCCESS → sshd 放行
```

要让这条链路成立，目标主机端必须做三件事：

1. **安装 `vault-ssh-helper` 二进制程序**（[GitHub
   releases](https://github.com/hashicorp/vault-ssh-helper)）
2. **写 helper 配置**：`vault_addr` 指向 Vault，`tls_skip_verify`
   或 CA 文件，`ssh_mount_point` 指向你挂的那个 SSH 引擎路径
3. **改 sshd PAM 流**：把 `auth` 阶段从默认的 `pam_unix.so` 换成
   `pam_exec.so + vault-ssh-helper`；并打开 sshd 的
   `ChallengeResponseAuthentication yes` / `UsePAM yes`

Vault 这一侧的 role 配置就简单得多：

```bash
vault write ssh/roles/otp_key_role \
    key_type=otp \
    default_user=ubuntu \
    cidr_list=172.17.0.0/16
```

`cidr_list` 是 OTP 模式特有的——它限定"这个 role 只能给这些 IP 段
内的主机签 OTP"。CA 模式不需要这个字段，因为 CA 模式的"哪些主机能
被登"由 sshd 自己管，Vault 只管签发证书。

**OTP 与 CA 的本质架构差**：

- CA 模式：Vault 是**离线签发方**，登录瞬间不需要 Vault 在线（证书
  自包含验证信息，sshd 用本地 CA 公钥就能验）
- OTP 模式：Vault 是**在线验证方**，每次登录目标主机的 helper 都要回
  调 Vault；Vault 一旦不可达，所有 SSH 登录立刻失败

这一条差异是 §7 选型对比里最重要的运维侧考量。

---

## 7. CA vs OTP：选型对比

| 维度 | CA 模式 | OTP 模式 |
| :--- | :--- | :--- |
| **目标主机改造** | 配一行 `TrustedUserCAKeys` + 分发 CA 公钥文件 | 装 `vault-ssh-helper` 二进制 + 改 PAM + 改 sshd_config |
| **登录瞬间是否需要 Vault 在线** | ❌ **不需要**（sshd 本地用 CA 公钥验证证书） | ✅ **必须在线**（helper 要回调 Vault 验 OTP） |
| **客户端是否需要 SSH 私钥** | ✅ 需要（用户的 id_rsa） | ❌ 不需要（用密码登录） |
| **审计粒度** | 证书签发 = 一条 audit；登录本身不经过 Vault | 每次登录 = 一条 audit（含 IP / role / 时间） |
| **TTL 控制** | 证书 TTL（推荐 ≤ 5 分钟） | OTP 寿命 = 一次使用 |
| **多平台支持** | 任何支持 OpenSSH 5.4+ 的系统（Linux/BSD/macOS/网络设备） | 必须能装 helper + 能改 PAM（基本只有 Linux） |
| **横向扩展时新增主机的成本** | ✅ 极低：分发同一个 CA 公钥即可 | ⚠️ 高：每台都要装 helper、配 PAM、加 cidr_list |
| **撤权速度** | 等当前最大证书 TTL（5min 起） | 立即（下一次登录就被拒） |
| **对零信任 / 跨域场景** | ✅ 友好（证书自包含、可跨网） | ⚠️ 一般（每次登录强依赖 Vault 网络可达） |

**经验法则**：

- 服务器规模 > 10 台，**毫无疑问选 CA**。运维负担基本恒定，加机器
  零成本
- 主机出于合规 / 老旧 / 厂商限制只支持密码，且能装 helper，**选
  OTP**
- 既不能改 sshd 又不能装 helper（例如纯第三方设备）——**两种都用不
  上**，需要在 Vault 之前架个跳板（Bastion），让跳板按 §3–§5 用 CA
  接进来即可

---

## 8. 一些常见错误的对照表

[官方 troubleshooting 段落](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates#troubleshooting)
列得相对零散，下面整理成一张表方便速查。本章实验里几种典型故障会让
你亲手撞一次，撞了之后再看这张表会更有体感。

| 现象 | 根因 | 解决 |
| :--- | :--- | :--- |
| 签发时报 `empty valid principals not allowed by role`（1.15+） | role 没设 `default_user`，请求也没传 `valid_principals` | role 加 `default_user=ubuntu`，或签发时显式 `valid_principals=...` |
| `Permission denied (publickey)`，sshd 日志里 `name is not a listed principal`（老版 Vault 才会走到这一步） | 同上，但签出来的证书 principals 是空的 | 同上 |
| 登入后看到 `PTY allocation request failed on channel 0`，会话卡住 | role 没设 `default_extensions={permit-pty:""}`，证书没有 PTY 权限 | 加上 `default_extensions`；按 `Ctrl-D` 退出卡住会话 |
| OpenSSH 8.2+ 报 `no mutual signature algorithm` | 客户端 / 服务端默认禁用了 `ssh-rsa` 签名算法 | role 加 `algorithm_signer=rsa-sha2-256`；或目标 sshd 加 `CASignatureAlgorithms ^ssh-rsa` |
| OTP 登录密码总是被拒 | sshd 没开 `ChallengeResponseAuthentication yes`，或 PAM 里 helper 行写错 | 检查 `/etc/ssh/sshd_config` 与 `/etc/pam.d/sshd`；用 `vault-ssh-helper -verify-only` 自检 |
| `ip is not part of the allowed cidr_list` | OTP role 的 `cidr_list` 没覆盖目标主机的 IP | `vault write ssh/roles/<role> cidr_list=...` 把目标段加进去 |

---

## 9. 实验

下一步进入实验：在 Killercoda 上用 Docker 容器作为 SSH 目标主机
（**全程不动宿主机的 sshd**），把 CA 模式 + Host Key Signing + OTP
模式三条路径全部跑一次。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-ssh" title="实验：SSH 机密引擎 CA + Host Key Signing + OTP 全流程" />

---

## 参考文档

- [SSH Secrets Engine — 总览](https://developer.hashicorp.com/vault/docs/secrets/ssh)
- [Signed SSH Certificates](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates)
- [One-Time SSH Passwords](https://developer.hashicorp.com/vault/docs/secrets/ssh/one-time-ssh-passwords)
- [SSH Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ssh)
- [vault-ssh-helper GitHub](https://github.com/hashicorp/vault-ssh-helper)
- [OpenSSH ssh-keygen 证书章节 (man)](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
