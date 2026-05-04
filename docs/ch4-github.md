---
order: 44
title: 4.5 GitHub 认证：用个人访问令牌登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.5 GitHub 认证：用个人访问令牌登录 Vault

> **核心结论**：GitHub 认证方法（`github`）让运维 / 开发者**使用
> 一枚 GitHub Personal Access Token（PAT）**登录 Vault——它属于
> [4.2 章 §1](/ch4-auth-basic) 区分过的"可信第三方（trusted
> third-party）"模式：信任根放在 GitHub（PAT 由 GitHub 颁发），
> Vault 仅负责持这枚 token 向 GitHub 查询"你是谁、属于哪个 org、
> 属于哪些 team"。它**主要面向人类用户**——Vault 官方明确指出：
> "这是给运维和开发者直接通过 CLI 使用的"——而**不**适合给应用 /
> 工作负载使用，也**不走** OAuth 三方授权流程，仅依赖 PAT。本章梳
> 理这套机制的认证流程、Vault 实际调用的 GitHub API 端点、
> `organization_id` 的 TOFU 行为、team / user 两级 policy 映射、
> SSO PAT 的常见陷阱、以及 GHES 私有部署对应的 `base_url`，并通过
> 动手实验**用 Prism + Nginx + 自签证书 + hosts 劫持**搭建一个
> "假 GitHub"，让 Vault 在毫无察觉的状态下走完一整套真实的认证流
> 程。

参考：
- [GitHub Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/github)
- [GitHub Auth API](https://developer.hashicorp.com/vault/api-docs/auth/github)
- [GitHub Personal Access Tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)

---

## 1. GitHub 认证在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 中的分类表：GitHub 认证落在"用户型 +
trusted 3rd-party"双重身份——它**主要适合人类直接使用**（HashiCorp
官方原话："most useful for humans"）：开发者打开笔记本、登录 GitHub、
生成一枚 PAT，然后执行 `vault login -method=github token=...` 即可
完成身份验证。Vault 把这枚 PAT 当作"GitHub 给我证明你是谁"的代币——
**不保存 GitHub 密码**、**不发起 OAuth 授权流程**，所有"这个用户是
不是真的某个人"的判断都由 GitHub 做。

> **PAT 在 Vault 内部的留存**：虽然不存密码，但 Vault 会把 PAT 本身
> 写进**该 token 的 InternalData**（`pathLogin` 里的 `InternalData:
> map[string]interface{}{"token": token}`）——用于 token 续期时重
> 新调一次 `verifyCredentials` 校验 PAT 仍然有效。意味着拿到 Vault
> token 的存储后端读权限的人**可能反向掏出 PAT**——这与所有 bearer
> token 类敏感数据需要按机密对待是一致的，不要因为"Vault 不存密码"
> 就低估这个面。

> **不要给应用用**：给应用 / CI / 容器用应当走
> [`approle`](/ch4-app-role)、[`aws`](/ch4-aws)、`kubernetes`、
> `jwt/oidc` 这些"工作负载身份型"方法——PAT 一旦泄漏就是个能登 Vault
> 的明文长效凭据，没有 IP 绑定 / 自动轮转 / 短寿命窗口可言。GitHub
> 认证不是协议层禁止机器使用，但生态最佳实践不推荐。

> **不走 OAuth 三方授权流程**：很多人第一反应是"GitHub 登录 = OAuth
> redirect"——Vault **不**做这件事，**不**当 GitHub OAuth App
> 注册，纯粹接受用户带上来的 PAT。原因：Vault 不愿意持有一个能代用
> 户操作 GitHub 的高权限凭据；让用户自己在 GitHub 上签发 / 销毁
> PAT 反而把权力留给本人。

---

## 2. 认证流程：Vault 调用的 GitHub API

PAT 一交到 Vault 手里，Vault 内部用 `google/go-github` SDK 真实调用
GitHub REST API。**配置阶段**与**登录阶段**调用的端点存在差异：

| 阶段 | 请求 | 何时被调用 | 用途 |
| :-- | :-- | :-- | :-- |
| 配置 | `GET /orgs/{org}` | `vault write auth/github/config organization=...` 但**未填 `organization_id`** 时 | TOFU 该 org 的数字 ID 写进 `config.organization_id`（见 §4） |
| 登录 | `GET /user` | 每次 `vault login -method=github` | 获取 PAT 对应的用户名 → 写进 token metadata 的 `username` |_id`** 时 | TOFU 该 org 的数字 ID 写进 `config.organization_id`（见 §4） |
| 登录 | `GET /user` | 每次 `vault login -method=github` | 拿到 PAT 对应的用户名 → 写进 token metadata 的 `username` |
| 登录 | `GET /user/orgs` | 每次登录（按 100/页分页） | 列举该用户所属 org，比对 ID 必须命中 `config.organization_id` |
| 登录 | `GET /user/teams` | 每次登录（按 100/页分页） | 列举该用户所属 team，过滤出属于目标 org 的 team，去查 `map/teams/<team>` 配置过的 policy |

**正常稳态下，登录会发起 3 次调用**（`/user` + `/user/orgs` +
`/user/teams`）；`/orgs/{org}` 只有在 `organization_id` 仍未学到时
（首次写 config 或旧版本配置升级）才会被调用一次。

> **`Accept` header（Vault 1.19.2 实测）**：`/user`、`/orgs/{org}`、
> `/user/orgs` 三条使用 `application/vnd.github.v3+json`；`/user/teams`
> 这条则因为 **Vault 1.19.2 vendored 的 `github.com/google/go-github
> v17.0.0+incompatible`** 内部实现，仍然发送
> `application/vnd.github.hellcat-preview+json`（一个早期 GitHub 团
> 队 API 的 preview media type，对应 nested teams 功能预览）——这
> 是动手实验里 mock spec 必须覆盖该 content-type 的原因，否则会被
> Prism 以 406 拒绝。
>
> 这是 `go-github` 旧版本的实现细节；将来 Vault 升级 SDK 后，这条
> Accept 可能切换回 `vnd.github.v3+json`——所以**不应**把它当作
> GitHub API 的协议合同。验证当前 Vault 版本实际发送的内容，最快的
> 办法就是查看 nginx access.log（实验 step 3 会做）。

> **从不向 GitHub 提交任何 write 操作**：Vault 只读 `/user`、
> `/user/orgs`、`/user/teams`、`/orgs/{name}` 四个端点。给 PAT 任何
> 写权限都是多余的。

---

## 3. PAT 的范围（scope）

PAT 可以是 **classic PAT** 也可以是 **fine-grained PAT**——两者权
限模型不同：

- **Classic PAT**：勾选 `read:org`（"Read org and team membership,
  read org projects"）即可——Vault 文档明确点名的就是这个 scope。
  勾选后 GitHub 就会在 `/user/orgs` / `/user/teams` 上对该 PAT 返
  回完整名单；不勾选时这两条 API 会返回空数组，Vault 判定"用户不在
  所需 org"并直接拒绝。
- **Fine-grained PAT**：没有同名 `read:org` scope，权限按 organization
  细分。至少要在 organization permissions 下勾 **"Members: Read-only"**
  让 PAT 能读到 org / team membership——具体要求随 GitHub 平台演进
  会调整，建议以测试为准（用一枚 fine-grained PAT 直接 `curl -H
  "Authorization: Bearer ghp_..." https://api.github.com/user/teams`
  能列出 team 即可）。

> **SSO 强制 org 的坑**：如果该 org 启用了 SSO，PAT 即便有正确的
> scope / permission，也必须在 GitHub 网页上**显式 authorize 该 PAT
> 对该 org 用 SSO**——否则 GitHub 不会把该 org 的 membership / team
> 信息透露给该 PAT。Vault 看到的现象：登录可能成功但**找不到 team
> mapping、最终 token 只带 `default`**；也可能直接被判"用户不在所
> 需 org"拒绝——具体形态取决于 GitHub 当前对未授权 PAT 返回什么。
> 生产环境务必在 `vault login` 前在 GitHub 网页 authorize PAT。

---

## 4. `organization` vs `organization_id`：为什么 Vault 同时存两个

> **先解释一个术语**：**TOFU = Trust On First Use（首次使用即信任）**。
> 这是密码学 / 安全协议里的一种通用模式——系统在**第一次**接触某
> 个对象时，把当时获得的标识（公钥、指纹、数字 ID 等）记录下来作为
> "锚点"，之后所有的校验都拿后续看到的标识与这个锚点比对。最广为
> 人知的例子是 SSH：第一次连一台新服务器，客户端把对方的 host key
> 存进 `~/.ssh/known_hosts`；以后再连同一个 host，host key 不一致
> 就立刻报警。本节介绍的 `organization_id` TOFU 是同一思路的应用——
> 第一次写 config 时把 GitHub org 的数字 ID 记下来，之后不再相信
> "名字"。

![TOFU 防御 org 同名空壳冒名攻击的过程示意](/images/ch4-github/tofu-org-id-spoofing-defense.png)

历史上 Vault 的 GitHub 认证只校验 org **名字**——但 GitHub 的 org
名字**可以变更**（owners 在 settings 里 rename）。如果有人把目标
org rename 成另一个名字、再创建一个同名空壳 org，Vault 的认证就会
"看错人"——把空壳 org 误认为目标 org。

修复：Vault 改成先校验 org **数字 ID**，名字仅用于反查 / 生成
warning。`organization_id` 在 `auth/github/config` 上是个独立字段：

- 写 `config` 时**只填 `organization=hashicorp`**：Vault 会立即调用
  一次 `GET /orgs/hashicorp` 把 `organization_id` 学回来（**TOFU**——
  trust on first use），写进 storage。
- 之后如果原 org 被 rename，Vault 仍然用学到的 ID 校验——空壳同名 org
  即使创建出来也不会被识别为目标 org。
- 也可以**显式手填 `organization_id=761456`**，跳过 TOFU——这是更安
  全的做法，但要求事先知道这个数字。
- 写 `config` 时如果填的 `organization` 在 GitHub 上**不存在**，
  Vault 会直接拒绝，错误信息形如 `unable to fetch the organization_id`。

> **企业版 GHES 必须显式填 `organization_id`**：Vault 文档明确指出
> "If you use GitHub Enterprise, you must set the `organization_id`
> parameter"——因为 GHES 上 `GET /orgs/{name}` 这个端点未必匿名可
> 访问，TOFU 会失败。

---

## 5. Authorization 工作流：team-map + user-map

login 成功后，Vault 计算 token 的 policy 列表，按以下顺序叠加：

1. `auth/github/map/teams/<team-slug>` 里 value 字段配置的 policy。
   **官方文档明确要求 team 名字 slugified**（`Site Reliability` →
   `site-reliability`）；建议遵守这条要求。如果一个用户属于多个
   team，所有匹配到的 policy 都会叠加。
2. `auth/github/map/users/<github-login>` 里 value 字段配置的 policy
   （这是**追加**——在 team policy 之上再加）。
3. GitHub 映射本身**不额外添加** `default`；但 Vault 通用机制会给
   每个 token 自动加上 `default`，除非配置了 `token_no_default_policy`。

> Vault 的 path 名字写的是 "map/teams"——但实际上一个 team 的
> mapping value 也是个 policy 名 / 列表。建议存储的就是 policy 名
> 而不是 team 名。

> **找不到任何匹配？** Vault 不会报错，token 只携带 `default`——
> 意味着该 token 几乎无法执行任何操作（仅能 lookup 自身、操作
> cubbyhole）。这是个相对安全的默认：未知 team 不授予任何额外权限。

### 5.1 team 的归属判断

Vault 收到 `/user/teams` 返回的列表后，**只保留 `organization.id`
等于 `config.organization_id` 的 team**——避免"我属于另一个 GitHub
org 的某个名为 dev 的 team，却在你这套 Vault 上意外获得 dev policy"
这种跨 org 权限串扰。

### 5.2 team name 与 slug 双匹配（实现细节，不要依赖）

阅读 `path_login.go` 时会发现：Vault 内部对每个 team **同时按
`team.name` 与 `team.slug` 查一次** `map/teams`——例如 name 是
`Site Reliability`、slug 是 `site-reliability`，两者都会被尝试。

这是历史遗留实现，**不应**作为运维约定。官方文档要求 slugified；
按 slug 写最稳妥：name 可以由 owner 任意修改、slug 一旦确定变更
慎重。依赖 name 命中，未来可能在 SDK 升级 / 实现重构时悄然失效。

---

## 6. token metadata 与 alias

Vault 给 GitHub 登录签出的 token 自带两个 metadata 字段：

| 字段 | 来源 |
| :-- | :-- |
| `username` | `GET /user` 返回的 `login` 字段——GitHub 上的用户名 |
| `org` | 命中 `organization_id` 的那个 org 的 `login`——名字（不是 id） |

token 的 `display_name` 形如 `github-<username>`——审计日志里很容
易识别出登录的具体身份。

每次登录还会创建一个 **identity alias**——alias name 就是 GitHub
用户名。这与 [2.5 章 identity entity](/ch2-identity-entity) 那套机
制整合在一起：同一个 GitHub 用户在多个 auth method（GitHub /
LDAP / OIDC）登录后，可以归并到同一个 entity。

---

## 7. PAT 泄漏的风险模型

PAT 是**长效**凭据——默认无过期（GitHub 近期推荐设置过期时间，但
PAT 本质是 bearer token）；**任何持有这枚 PAT、且能访问 Vault 端点
的人**，都能冒充该用户登录 Vault。Vault 文档第二段就明确指出："If
such a token is stolen from a third party service, and the attacker
is able to make network calls to Vault, they will be able to log in
as the user that generated the access token."

缓解措施：

- 使用 **fine-grained PAT** + 自觉设置短过期；GitHub 用户级别允许
  "无过期"，但 organization / enterprise 可以**强制最大有效期**——
  GitHub 平台政策与 org 配置随时调整，以你所在 org 实际允许的最长
  寿命为准
- Vault 端在 `config/token_*` 上设置短 `token_ttl` /
  `token_max_ttl`，让"PAT 持有者一天能登录一次获得的 Vault token"
  也保持短寿命
- `config/token_bound_cidrs` 限定 PAT 只允许从特定网段登录
- 真正高敏感的运维操作应启用 [4.x MFA / 多因素] 章节会介绍的额外认
  证层
- 长期方向：用 OIDC（后续 4.x 章节会展开）把 GitHub 接入企业
  SSO，作为 PAT 的过渡方案

> **不要把 PAT 写入 CI 系统的环境变量**——CI 自动化场景应当使用
> `jwt`（GitHub Actions OIDC token）或 [`approle`](/ch4-app-role)，
> 而不是把人类 PAT 共享给机器。

---

## 8. 标准配置流程速记

按官方文档的流程，运维一次性把 GitHub 认证启用 + 配置好通常是：

```bash
# 1. 启用 auth method（默认挂在 auth/github/）
vault auth enable github

# 2. 配置 organization（首次写会触发 TOFU 学回 organization_id）
vault write auth/github/config organization=hashicorp

# 3. 把 team / user 映射到 policy
vault write auth/github/map/teams/dev value=dev-policy
vault write auth/github/map/users/sethvargo value=sethvargo-policy
```

> **挂载到非默认路径**：执行 `vault auth enable -path=my-gh github`
> 之后所有 path 都从 `auth/my-gh/` 开始；登录命令也要相应带上
> `-path=my-gh`：`vault login -method=github -path=my-gh
> token=ghp_...`。**不要遗漏 `-path` 这个参数**——同一台 Vault 上
> 挂载多个 GitHub auth method（比如对应不同 org）是常见做法。

## 8.1 CLI / API / 环境变量

**CLI**（Vault 内建支持，最常用）：

```bash
vault login -method=github token=ghp_xxxxxxxx
# 挂载在非默认路径：
vault login -method=github -path=my-gh token=ghp_xxxxxxxx
```

**环境变量**（CI 偶尔使用，PAT 仍需事先注入）：

```bash
export VAULT_AUTH_GITHUB_TOKEN=ghp_xxxxxxxx
vault login -method=github
```

**HTTP API**（偶尔用于脚本调试）：

```bash
curl --request POST \
     --data '{"token":"ghp_xxxxxxxx"}' \
     "$VAULT_ADDR/v1/auth/github/login"
```

返回 JSON 中的 `auth.client_token` 就是 Vault token；`auth.metadata`
中包含 `username` / `org`；`auth.policies` 则是最终生效的 policy
列表。

---

## 9. `base_url`：自建 GHES 与"假 GitHub"

`auth/github/config.base_url` 默认为空——Vault 使用 `go-github` 的
内置默认值 `https://api.github.com/`。修改 `base_url` 的两个典型场
景：

- **GitHub Enterprise Server（GHES）**：填
  `https://github.example.corp/api/v3/`——Vault 把所有 API 调用都
  发往这个 base。
- **本地模拟 / 测试**：填 `http://127.0.0.1:4010/`——指向本地启动
  的 mock server，**完全跳过 TLS 与公网**。

**两种 mock 方式的本质差异**：

| 路径 | `base_url` 改成 mock | 不动 `base_url`，hosts + 自签证书劫持 `api.github.com` |
| :-- | :-- | :-- |
| 改的是谁 | Vault 自身的配置 | 操作系统层面的 DNS + TLS 信任根 |
| 演示价值 | 仅证明 Vault 与 mock 间的交互可达 | 完整呈现 Vault 是如何"识别" GitHub 的（DNS 解析 + TLS 信任链 + HTTP 协议三层） |
| 是否为 GHES 接入推荐路径 | ❌（用于本地实验 / 单元测试） | ❌（**绝对不要**用 hosts/CA 劫持当作 GHES 生产接入方案；GHES 正确路径是 `base_url=https://<ghes-host>/api/v3/` + 显式 `organization_id`） |

本章动手实验采用第二种——目的是**协议演示与故障注入**，同时呈现
Vault 内部是使用 Go 的 `crypto/tls` 默认 SystemCertPool 来加载根
CA：把自签 CA 写入 `/usr/local/share/ca-certificates/` 后执行
`update-ca-certificates`，新启动的 Vault 进程便会将其视为合法 CA。

> ⚠️ **不要把这条实验路径误读为 GHES 生产接入指南**：真实 GHES 部
> 署应当使用 `base_url` 显式把 Vault 指向 `https://<ghes>/api/v3/`、
> 显式填写 `organization_id`、并使用合法 CA 链（内部 PKI 或公网 CA）
> 签发的证书；DNS / hosts 劫持仅用于隔离环境的演示与故障注入场景。

---

## 10. config 字段速记

| 字段 | 必填 | 说明 |
| :-- | :-- | :-- |
| `organization` | 是 | GitHub org 名（GitHub 上 URL 里那个名字） |
| `organization_id` | 否（推荐显式填） | 不填则 TOFU；GHES 上必填 |
| `base_url` | 否 | 默认 `https://api.github.com/`；GHES / mock 必填 |
| `token_ttl` / `token_max_ttl` | 否 | 签出 token 的 TTL；默认走 mount tune |
| `token_bound_cidrs` | 否 | 限定登录方源 IP CIDR 列表 |
| `token_explicit_max_ttl` / `token_period` / `token_no_default_policy` / `token_num_uses` / `token_type` | 否 | [auth tune 通用字段](/ch2-auth-tokens) |

---

## 11. 与 LDAP / OIDC 的横向对比

| 维度 | `github` | [`ldap`](/ch3-ldap)（如果包含 LDAP 认证章节） | `oidc` |
| :-- | :-- | :-- | :-- |
| 凭据颁发方 | GitHub（PAT） | 企业 AD / OpenLDAP（用户名+密码） | 企业 IdP（OIDC ID Token） |
| 走 OAuth 流程 | 否（直接 PAT） | 否（用户名+密码） | 是（标准 OAuth2） |
| 单点登录体验 | 差（需手动复制 PAT） | 中（输入密码） | 好（浏览器一次跳转） |
| 适用场景 | GitHub 重度团队 / 开源项目 | 已有 AD 的传统企业 | 现代云原生 / 企业 SSO |
| 撤销时延 | 高（PAT 不联动 Vault） | 中（密码修改后立即生效） | 低（IdP 撤销后下次刷新失败） |
| 给应用使用 | ❌ | ❌（除非 service account） | ⚠️（建议 jwt） |

新部署优先选用 OIDC + 企业 IdP；GitHub 认证更适合"团队主要在 GitHub
组织内活动、且用户人数不多"的场景。

---

## 12. 实验

下一步进入实验：在 Killercoda 上**用 Prism mock GitHub API + Nginx
TLS 反代 + 自签证书 + /etc/hosts 劫持**，搭建出一个让 Vault 完全无
法分辨真伪的 "api.github.com"，再走完整 GitHub 认证链路——`vault
login -method=github token=...` 让 Vault 真实调用 GitHub API、TOFU
学回 org id、按 team 映射出 policy、签发 token。

> 这个实验有意**不**采用 `base_url` 改 mock 的捷径——`base_url`
> 留空，让 Vault 默认去访问 `https://api.github.com/`，然后由操作
> 系统层面把该域名重定向到本机。完整跑完一次实验，既能完整呈现
> Vault 与 GitHub 之间的协议交互细节，也能彻底理解 Vault 的 TLS
> 信任链是如何对接到系统 CA 根的——同样的手法在隔离环境中做协议
> 演示与故障注入时都会反复用到。

> **真实度提示**：Prism 的 mock 行为是"按 spec 里 `example` 字段
> 静态返回"——因此无论传入哪一枚 PAT，mock 都会返回同一个
> `testuser`。这一特性在第 4 步会被刻意利用：通过修改 mock spec 构
> 造"用户在另一个 org"、"团队不存在"等失败现场。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-github" title="实验：GitHub 认证完整动手——Prism + Nginx + 自签证书 + hosts 劫持搭假 GitHub" />

---

## 参考文档

- [GitHub Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/github)
- [GitHub Auth API](https://developer.hashicorp.com/vault/api-docs/auth/github)
- [GitHub Personal Access Tokens — Classic vs Fine-grained](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [Terraform — GitHub auth method backend](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/github_auth_backend)
- [Stoplight Prism — OpenAPI mock server](https://github.com/stoplightio/prism)
- [google/go-github — Vault 内部使用的 GitHub SDK](https://github.com/google/go-github)
