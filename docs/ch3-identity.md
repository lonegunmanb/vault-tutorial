---
order: 36
title: 3.6 Identity 机密引擎：Vault 的身份中枢与 OIDC 提供商
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.6 Identity 机密引擎：Vault 的身份中枢与 OIDC 提供商

> **核心结论**：和 [3.4 Cubbyhole](/ch3-cubbyhole) 一样，`identity/`
> 是 Vault **默认挂载、不可禁用、不可迁移**的特殊内置引擎——但它的
> 任务不是"存数据"，而是给整个集群当**身份中枢**。它对外暴露三件事：
>
> 1. **身份对象的 CRUD**：Entity / Group / Alias 的增删改查 API（背后
>    的概念在 [2.5 身份实体](/ch2-identity-entity) 已经讲过，本章不再
>    重复，只关心"通过 `identity/` 引擎怎么操作"）。
> 2. **Identity Tokens**：以 Vault 当前 Entity 的元数据为载荷，签发
>    符合 OIDC 规范的 JWT；公钥通过标准 `.well-known` JWKS 暴露，外部
>    系统可以脱离 Vault 验证。
> 3. **OIDC Identity Provider**：在 Identity Tokens 之上再封一层完整
>    的 Authorization Code Flow + Discovery，让 Vault 反向变成下游应
>    用的**单点登录服务器**——这是 [7.11 / 7.12](/) 的底层支撑。
>
> 此外，Vault 1.19 引入了 **identity 去重（deduplication）激活机制**，
> 用来一次性清理历史 bug 留下的重复 entity / alias / group——这是
> 运营老 Vault 集群升级到 1.19+ 后必做的一道作业。

参考：
- [Identity Secrets Engine — Overview](https://developer.hashicorp.com/vault/docs/secrets/identity)
- [Identity Tokens](https://developer.hashicorp.com/vault/docs/secrets/identity/identity-token)
- [OIDC Identity Provider](https://developer.hashicorp.com/vault/docs/secrets/identity/oidc-provider)
- [Find and resolve duplicate Vault identities](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication)
- 已学概念：[2.5 身份实体](/ch2-identity-entity)、[2.4 Token](/ch2-auth-tokens)、[3.4 Cubbyhole](/ch3-cubbyhole)（"内置不可拆"模型的同类）

---

## 0. 一句话定位与三种用法

把 `identity/` 引擎想成 Vault 自带的一间**"户政公证处"**：

- 它有一本**户籍册**（`identity/entity` `…/group` `…/entity-alias`）——
  集群里"谁是谁、谁属于哪个组、同一个人在不同窗口下挂的小名是哪些"
  全在这本册子上。这本册子在 [2.5 身份实体](/ch2-identity-entity) 里
  讲过概念，本节给"册子的窗口办事 API"。
- 它会按申请**出具盖章证明书**（`identity/oidc/token/<role>`）——
  你（一个已经登录 Vault 的 Entity）走到柜台，柜台按你提交的 role
  模板，从册子里抄出"你叫什么、属于哪个组、metadata 写了啥"，签好
  公章交给你，让你拿去给**任何不认识 Vault 的第三方**看。
- 它还能**直接当登录大厅**（`identity/oidc/provider/...`）——
  其他机构（下游应用）干脆把来访者**指路**到这间公证处："你先去那
  边登记，登记完拿一张盖了章的入门证回来给我看就行。" 来访者在公证
  处走完登录流程，公证处签一张同样格式的盖章证明书塞给来访者，让他
  带回去。

后两种用法用的**都是同一种"盖章证明书"——一条符合 OIDC 规范的 JWT**，
公章（公钥）通过标准 `.well-known` 端点公开发布，谁都能离线验签
（细节见 [§3](#_3-identity-tokens-让-vault-变成-jwt-签发机)）。区别只在
"谁去申请"和"在哪一步交付"：

| 用法 | 类比 | 谁主动 | 用户与 Vault 是否要交互 | 典型场景 |
| --- | --- | --- | --- | --- |
| **身份对象 CRUD**（[§2](#_2-身份对象-crud-entity-group-alias-的-工程视角)） | 户籍册的**填册子 / 查册子** | 管理员 / 自动归并 | — | 多 auth method 归并到同一个人；建项目组；做权限策略基础 |
| **Identity Tokens**（[§3](#_3-identity-tokens-让-vault-变成-jwt-签发机)） | 申请人**亲自上柜台**领一份盖章公证书带走 | 已登录的 Entity（往往是工作负载） | ❌ 无 UI、纯 API | 服务 A 拿着 Vault 签的 JWT 去访问不信任 Vault 的服务 B |
| **OIDC Identity Provider**（[§4](#_4-oidc-identity-provider-把-vault-反向变成-idp)） | 公证处兼营的**登录大厅** | 下游应用把用户**重定向**过来 | ✅ 必经 Vault Web UI | 给内部后台 / Boundary / Consul 加 SSO 登录 |

读完整章后再回头看这张表——后面 §1–§5 都是在把这三件事一件件展开。

![identity-overview](/images/ch3-identity/identity-overview.png)

---

## 1. 把 `identity/` 当成机密引擎重新审视

[3.4 Cubbyhole](/ch3-cubbyhole) 那一节我们提到："`cubbyhole/` 是
Vault 里两个被特殊锁死的内置引擎之一，另一个就是本节的 `identity/`。"
两者共同点是**默认挂载、不可禁用、不可迁移、不可二次挂载**——因为它
们承载的不是业务数据，而是 Vault 自身的运行时基础设施（Cubbyhole 撑
Token 体系，Identity 撑身份与 OIDC 体系）。区别在于"数据归属维度"和
"主要用途"：

| 维度 | `cubbyhole/`（[3.4](/ch3-cubbyhole)） | `identity/`（本节） |
| --- | --- | --- |
| 默认挂载 | ✅ | ✅ |
| `vault secrets disable` | ❌ | ❌ |
| `vault secrets move` | ❌ | ❌ |
| 二次 `enable` | ❌ | ❌ |
| 数据归属维度 | Token 私有 | 集群全局 |
| 主要用途 | 临时存储 / Wrapping 载体 | 身份对象 + Token 签发 + OIDC Provider |

实战意义：你**不需要也不应该**为 `identity/` 操心"什么时候挂上"——
它生而存在；你能做的全部操作都在它的子路径下：

```
identity/
├─ entity/                  ← Entity CRUD（2.5 概念的 API 入口）
├─ entity-alias/            ← Alias CRUD
├─ group/ , group-alias/    ← Group CRUD
├─ lookup/entity, lookup/group
├─ oidc/                    ← Identity Tokens：keys / roles / token / introspect
└─ oidc/provider, oidc/client, oidc/scope, oidc/assignment
                            ← OIDC Identity Provider：把 Vault 变 IdP
```

记住这张子路径地图，本章后面所有命令都能映射回来。

---

## 2. 身份对象 CRUD：Entity / Group / Alias 的"工程视角"

**概念回顾**（已在 [2.5](/ch2-identity-entity) 详细讲过）：

- **Entity**：跨 auth method 稳定的"人"或"工作负载"
- **Alias**：一个 Entity 在某个具体 auth mount 上的"分身"——一个
  Entity 在同一个 auth mount 下**最多一个 alias**
- **Group**：Entity 的集合；可嵌套；可以有自己的 Alias（"外部组
  → 内部组"映射）

本节只补充三个**工程上很容易踩坑、但 [2.5](/ch2-identity-entity) 没展
开**的细节：

### 2.1 Alias 必须挂到一个具体的 auth mount accessor 上

很多人第一次写 `vault write identity/entity-alias` 会忘记 `mount_accessor`
参数——Vault 会拒绝，因为 alias 的"身份"必须能定位到一个具体的 auth
mount。Mount accessor 是 mount 的全局唯一不变 ID（不是 path！）：

```bash
# path 可以改，accessor 不会变
vault auth list -format=json | jq -r 'to_entries[] | "\(.key) \(.value.accessor)"'
# userpass/ auth_userpass_8a1b2c3d
```

`mount_accessor` 字段填的是后面那串 `auth_userpass_...`。这就是为什么
即使把 auth mount 改名（[5.7 Mount Migration](/ch5-mount-migration)），
身份归并不会断——绑的是 accessor 不是 path。

### 2.2 "同名自动归并" vs "手动归并"

当一个用户首次通过某 auth method 登录、且**该 mount 的 alias name 与
某个已有 Entity 的某个 alias 不冲突**时，Vault 会**新建** Entity；如
果 alias name 在该 mount 下已存在，则复用。

但**跨 mount 的"这两个登录其实是同一个人"是 Vault 自己看不出来的**
——你必须显式 `vault write identity/entity-alias` 把第二个 alias 挂
到已有 Entity 上。这就是 [2.5](/ch2-identity-entity) 反复强调的"归并
靠人"。

### 2.3 Group 的两种模式

| 类型 | `type` 字段 | 成员怎么来 | 典型场景 |
| --- | --- | --- | --- |
| internal | `internal`（默认） | 显式 `member_entity_ids` / `member_group_ids` | 自己定义的"项目组" |
| external | `external` | 由 alias 从外部 IdP 同步（如 LDAP `memberOf`、OIDC `groups` claim） | 复用企业目录现成的组结构 |

**External group 不能塞 `member_entity_ids`**——它的成员关系完全由外
部 IdP 在登录时自动写入，你只能配 alias 把"外部组名"映射到这个 Vault
Group。

---

## 3. Identity Tokens：让 Vault 变成 JWT 签发机

> **一句话定位**：Identity Tokens 让 Vault 能为 *已登录的 Entity* 签
> 发一个**符合 OIDC 规范的 JWT**，公钥通过标准 `.well-known` 端点对
> 外暴露——任何懂 JWT 的下游系统都能在**完全不查询 Vault** 的情况下
> 验证这条身份声明。

这是把 Vault 从"机密存储"升级成"身份发证机关"的关键一跳。

### 3.0 先把 JWT 搞清楚

后面所有讨论都建立在"JWT 是个什么东西"之上。如果你已经熟悉，可以直
接跳到 §3.1；不熟悉的话，这一节是必读。

**JWT (JSON Web Token, [RFC 7519](https://datatracker.ietf.org/doc/html/rfc7519))**
是一个**自我描述、可独立验证**的字符串。它的结构永远是三段，用 `.`
分隔：

```
   eyJhbGciOiJSUzI1NiIs...   .   eyJpc3MiOiJodHRwczovL3Z...   .   X9c8WfH3...
   └─────── Header ────────┘     └────── Payload ─────────┘    └─ Signature ─┘
        base64url(JSON)                base64url(JSON)         二进制签名 base64url
```

- **Header**：声明签名算法（如 `{"alg":"RS256","typ":"JWT","kid":"…"}`）。
  `kid` 是"用了哪把公钥签的"——验证方靠它去 JWKS 里找对应的公钥。
- **Payload**：一段 JSON，里面是若干**Claim（声明）**——也就是"这
  个 token 在断言什么事实"。
- **Signature**：用签名算法 + 私钥对前两段做的密码学签名。

**核心安全性质**：前两段是**明文 base64**，任何人都能解出来读
（`echo "$JWT" | cut -d. -f2 | base64 -d` 即可）；但**没有对应的私钥
就无法生成有效的第三段**。所以 JWT 不是"加密"，而是"防篡改的签名声
明"——**不要把密码、密钥这种敏感字段放进 payload**。

#### OIDC 规定的标准 Claim

OpenID Connect 在 JWT 之上规定了一组**ID Token 必须有**的 claim
（见 [OIDC Core §2](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)），
Vault 签出来的 token 一定带上：

| Claim | 含义 |
| --- | --- |
| `iss` | **Issuer**——签发者 URL，验证方据此找 JWKS |
| `sub` | **Subject**——这条 token 在描述谁（Vault 里 = Entity ID） |
| `aud` | **Audience**——预期接收方（Vault 里 = role 的 `client_id`） |
| `iat` | **Issued At**——签发时间（Unix 秒） |
| `exp` | **Expiration**——过期时间（Unix 秒）；超过即视为无效 |
| `nbf` | **Not Before**（可选）——这个时间之前不接受 |
| `nonce` | （OIDC 流程里）防重放随机串，由 RP 在请求时给定、token 原样回填 |

除了这些标准字段，签发方还可以加任意**自定义 claim**——这正是
[§3.3](#_3-3-模板-把-entity-元数据塞进-jwt) 模板的用武之地。

#### 验证一条 JWT 的标准动作

无论用哪种语言的 JWT 库，验证步骤都一样：

1. 解出 header，拿到 `alg` 与 `kid`
2. 从 issuer 的 JWKS 端点（`<iss>/.well-known/keys`）拉公钥列表，按
   `kid` 找到对应公钥
3. 用该公钥按 `alg` 校验第三段签名 → **签名有效性**
4. 校验 `exp > now`、`nbf <= now`（如有）、`aud` 等于本服务的预期
   client_id、`iss` 等于预期签发者 → **业务有效性**
5. 全部通过 → 信任 payload 里的所有 claim

记住：**JWT 验证完全是离线的**——除了首次拉一次 JWKS 公钥（之后还可
以缓存），不需要再回头问签发者。这就是它能取代"每次请求都查一次中央
session 服务器"的根本原因，也是 [§3.4](#_3-4-验证侧-两种姿势) 推荐
JWKS 路线、§3.4 把 introspect 列为"高敏特例"的依据。

### 3.1 三个核心对象：Key / Role / Token

```
identity/oidc/key/<name>     ← 命名密钥对（Vault 帮你生成 + 自动轮转的 RSA/EC 私钥）
identity/oidc/role/<name>    ← 模板 + TTL + 引用某个 key + 限定 client_id
identity/oidc/token/<role>   ← 当前 token 的持有者（Entity）请求签发一条 JWT
```

三者之间的关系是**多对一**：多个 role 可以共用一个 key；一个 role
对应固定的 client_id（也就是 JWT 里 `aud` 字段的值）。

### 3.2 Key 的两个关键参数：`rotation_period` 与 `verification_ttl`

- **`rotation_period`**（默认 24h）：每隔多久 Vault 自动生成一对新的
  签名密钥，并用新密钥签后续 token；旧的**私钥立即销毁**。
- **`verification_ttl`**（默认 24h）：旧的**公钥**在 JWKS 端点上还会
  保留多久——这是给"已经签出去、还没过期"的老 token 留的验证窗口。

> **配置规律**：`verification_ttl ≥ role.token_ttl` —— 否则 token
> 还没过期，公钥已经从 JWKS 上消失，下游验证全军覆没。

### 3.3 模板：把 Entity 元数据塞进 JWT

Role 上的 `template` 字段是一段 JSON（可选 base64 编码），里面用类
似 ACL 路径模板的占位符引用 Entity 信息：

```hcl
template = <<EOT
{
  "username":   {{identity.entity.aliases.auth_userpass_8a1b2c3d.name}},
  "groups":     {{identity.entity.groups.names}},
  "department": {{identity.entity.metadata.department}}
}
EOT
```

签出来的 JWT 会把这些字段**和标准 OIDC claim（`iss/sub/aud/iat/exp`）
合并**成最终 payload。常用占位符（[完整列表](https://developer.hashicorp.com/vault/docs/secrets/identity/identity-token#token-contents-and-templates)）：

| 占位符 | 说明 |
| --- | --- |
| `identity.entity.id` / `.name` | Entity 自身 |
| `identity.entity.groups.ids` / `.names` | 所属组 |
| `identity.entity.metadata.<key>` | Entity 元数据 |
| `identity.entity.aliases.<accessor>.name` | 在指定 auth mount 下的 alias 名 |
| `identity.entity.aliases.<accessor>.metadata.<key>` | Alias 元数据 |
| `time.now` / `time.now.plus.<dur>` | 当前时间 / 延后/提前的时间戳 |

⚠️ 模板的**顶层 key 不能与标准 OIDC claim 同名**（否则会覆盖 `iss/sub/...`）。

### 3.4 验证侧：两种姿势

签好的 JWT 怎么被下游系统验证？文档列了两条路：

| 验证方式 | 端点 | 是否需要 Vault Token | 优势 | 局限 |
| --- | --- | --- | --- | --- |
| **JWKS / OIDC Discovery**（推荐） | `…/identity/oidc/.well-known/openid-configuration` 与 `…/.well-known/keys` | ❌ 不需要 | 标准 OIDC 库直接对接；Vault 不在请求路径上 | 无法感知"Entity 已被禁用"等运行时状态 |
| **Introspection** | `identity/oidc/introspect` | ✅ 需要 | 多查一次"Entity 还活着没"，能识别中途禁用 | 增加 Vault 一次请求；要管验证侧的 Vault 凭据 |

> 大多数生产场景用 JWKS 即可——脱离 Vault、可缓存、与所有 OIDC 库
> 兼容。仅在"需要立刻反映 Entity 撤销"的高敏场景才上 introspection。

### 3.5 `iss`（Issuer）的网络可达性

签出去的 JWT 里 `iss` 字段的值就是 Vault 用来发布 JWKS 的 base URL。
默认取自 Vault 启动时配置的 `api_addr`。**下游验证方一定要能直连这
个地址**——典型坑：

- Vault 跑在内网，`api_addr=https://vault.internal:8200`，但下游服
  务在外网 → 验证拿不到 JWKS → 全部失败。
- 多集群部署但 token 在集群 A 签、却让集群 B 验 → JWKS 来自 A，`iss`
  字段也写的 A，B 自己的 JWKS 上没这把公钥 → 失败。

需要时用 `identity/oidc/config` 显式覆盖 `issuer`。

![identity-token-flow](/images/ch3-identity/identity-token-flow.png)

---

## 4. OIDC Identity Provider：把 Vault 反向变成 IdP

如果说 Identity Tokens 是"我自己问 Vault 要一张身份凭证给别人看"，
那 **OIDC Identity Provider 就是把整个标准 OIDC 登录服务器搬进
Vault**——下游应用走标准的 Authorization Code Flow，把用户**重定向**
到 Vault 来登录，然后拿回 ID Token。

### 4.1 默认就有一个 Provider

Vault 每个 namespace 自带一个名为 `default` 的 OIDC provider 和一把
名为 `default` 的 key。**这意味着启用一个完整 OIDC IdP 的最少操作只
有两步**：

1. 启用任一 auth method（`userpass`/`oidc`/`ldap` 都行——这决定终端
   用户拿什么登录 Vault）
2. 创建一个 `identity/oidc/client/<app>` 客户端，把 `assignments` 设
   为内置的 `allow_all`

之后下游应用就可以用 `client_id`、`client_secret` 和 issuer
`<vault>/v1/identity/oidc/provider/default` 三个值跑标准 OIDC 流。

### 4.2 五个核心对象

```
identity/oidc/provider/<name>     ← 网关：暴露 .well-known 与 authorize/token/userinfo 端点
   └─ allowed_client_ids          ← 哪些 client 能走这个 provider
   └─ scopes_supported            ← 这个 provider 提供哪些 scope
   └─ issuer                      ← JWT iss 字段值（同 Identity Tokens 的注意点）

identity/oidc/client/<name>       ← 一个下游应用
   ├─ client_type                 ← confidential（带 secret） / public（PKCE）
   ├─ redirect_uris               ← 允许重定向回的 URL（OIDC 安全核心）
   ├─ assignments                 ← 谁能通过这个 client 登录（默认空 → 全拒）
   └─ key                         ← 用哪把 named key 签 ID Token

identity/oidc/scope/<name>        ← 自定义 scope；模板语法同 §3.3
identity/oidc/assignment/<name>   ← Entity / Group 白名单
identity/oidc/key/<name>          ← 复用 §3.1 的 named key
```

### 4.3 Authorization Code Flow 在 Vault 里长什么样

下游应用（"relying party / RP"）侧的代码与对接 Auth0 / Keycloak 完
全一致——区别只在 **endpoint URL** 来自 `/identity/oidc/provider/<name>/.well-known/openid-configuration`：

```
authorization_endpoint:  /ui/vault/identity/oidc/provider/<name>/authorize
token_endpoint:          /v1/identity/oidc/provider/<name>/token
userinfo_endpoint:       /v1/identity/oidc/provider/<name>/userinfo
jwks_uri:                /v1/identity/oidc/provider/<name>/.well-known/keys
```

注意 `authorization_endpoint` **指向的是 Vault Web UI**——这是必然
的，因为用户需要在那里完成"输入用户名密码 / 点 GitHub 登录按钮"等
真实交互。Vault UI 走完 auth method 后，会按标准 OIDC 协议带着
`code` 参数 302 回 RP 的 `redirect_uri`。RP 拿 `code` 去 token 端点
换 `id_token`（+ 可选 `access_token`）。

支持的协议特性（开源版）：

- ✅ Authorization Code Flow
- ✅ PKCE（`S256` 与 `plain`）—— public client 推荐
- ✅ `client_secret_basic` / `client_secret_post` / `none` 三种 token
  端点认证
- ✅ Discovery（`.well-known/openid-configuration`）+ JWKS
- ❌ Implicit / Hybrid Flow（不支持，也不该用）

### 4.4 `assignments` 的"默认全拒"陷阱

`identity/oidc/client/<name>` 上的 `assignments` 字段**默认是空数组**
——空 = 一个人都不让进。这很反直觉，文档专门提示用内置的 `allow_all`
作为快速 demo 的"放行通配符"。

生产里的正确姿势是创建命名 assignment，把"允许走这个 client 登录的
Entity / Group"显式列出来：

```bash
vault write identity/oidc/assignment/admins \
  entity_ids="$ALICE_ENTITY_ID,$BOB_ENTITY_ID" \
  group_ids="$PLATFORM_TEAM_GROUP_ID"

vault write identity/oidc/client/admin-portal \
  redirect_uris="https://admin.internal/cb" \
  assignments="admins" \
  key="default"
```

> 这是把 Vault 当 IdP 时**最容易被忽视的安全卡点**——忘记加
> `assignments` 比忘记加 `redirect_uris` 还危险，因为前者会让你以为
> "登录失败是配置 bug"而不停放宽，最后干脆用 `allow_all` 上线。

### 4.5 与第 7 章的衔接

本节给的是"identity 引擎里的 OIDC 子模块怎么搭"。把 Vault 真正接入
一个具体的 RP（Boundary / Consul / 自研后台）、串完整端到端 SSO，是
[7.11 / 7.12](/) 的内容；本节实验只把"端点确实开起来 + ID Token 真
的能签出来"跑通。

![oidc-provider-flow](/images/ch3-identity/oidc-provider-flow.png)

---

## 5. 解决重复身份（Identity Deduplication，1.19+）

> **背景**：Vault 1.19 之前的若干旧版本存在 bug，可能在持久化存储里
> 留下**重复**的 entity / alias / group——比如同一个 alias 名因大小
> 写差异被存成两条。这些重复在日常使用中可能不引发明显症状，但会让
> "按身份计费 / 审计 / 策略归并"全部失真。
>
> Vault 1.19 起，启动时的 unseal 阶段会**主动检测并日志告警**重复，
> 并提供一个**一次性、不可回滚**的激活开关 `force-identity-deduplication`，
> 用来把重复彻底去掉。

### 5.1 五步标准流程（[官方流程](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication)）

1. **看日志**：在 active 节点系统日志里找 `core: post-unseal setup
   starting` … `setup complete` 之间的 `DUPLICATES DETECTED` 行。如
   果一条都没有 → 直接跳到第 5 步。
2. **梳理目标**：用官方给的 Bash 片段把日志切成
   `merge-details.txt`（自动合并的同名 alias）+ `rename-targets.txt`
   （需要被改名的 entity / group）。
3. **逐项处理**：根据"不同大小写 alias 重复"还是"entity / group 重
   复"两类问题，分别按 [different-case](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication/different-case)
   / [entity-group](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication/entity-group)
   两份子文档操作。**PR 副本集群要分别检查**——本地 alias 重复只在
   secondary 上能看到。
4. **评估延迟影响**：激活时所有节点会**重载内存身份缓存**——大集群
   可能阻塞请求十几秒甚至超过 30s。提前安排维护窗口。
5. **激活去重**：在 primary 上执行：
   ```bash
   vault write -f sys/activation-flags/force-identity-deduplication/activate
   ```

### 5.2 三个不可逆的事实

| 事实 | 含义 |
| --- | --- |
| **激活是单向操作** | 一旦点亮就**永远**回不去。该集群此后每次 unseal 都会强制再跑一遍去重检查。 |
| **未来 unseal 会更快** | 因为重复早已清零，去重检查变成纯校验、几乎零耗时——这是上线 1.19+ 之后的小红利。 |
| **DR 副本不需单独检查** | DR 副本不处理客户端写入 → 不会产生本地重复；只检查 primary 与 PR secondary 即可。 |

### 5.3 实战建议

- 升级到 1.19+ **当天**先看日志、判断是否有 `DUPLICATES DETECTED`，
  **不要急着激活**。
- 有重复时**先按 §5.1 第 3 步尽量手工解决**，再激活——激活后下次
  unseal 会自动处理残留的重复：同名 entity / group 会被**重命名**为
  `name-<uuid>`，同名 alias（同 mount_accessor + name）会触发 entity
  **合并**。两种操作都**不可逆**，所以激活前务必确认每组重复确实该处理。
- 维护窗口里激活；激活后看每个节点日志里的两行：
  ```
  INFO core: force-identity-deduplication activated, reloading identity store
  INFO core: force-identity-deduplication activated, reloading identity store complete
  ```
  之间的耗时就是这次"全集群身份缓存重载"的实际时长，作为下次容量
  评估的基准。

---

## 6. 路径与权限速查

| 想做的事 | 路径 | 备注 |
| --- | --- | --- |
| 创建 / 查 / 删 Entity | `identity/entity` & `identity/entity/id/<id>` | 按 ID；按 name 用 `identity/entity/name/<name>` |
| 把 Alias 挂到 Entity | `identity/entity-alias` + `mount_accessor` | 同一 mount 下一个 Entity 只能一个 alias |
| 创建 Group | `identity/group` | `type=internal` 显式列成员；`type=external` 走 alias 自动同步 |
| 跨 mount 查询身份 | `identity/lookup/entity` & `identity/lookup/group` | 调试归并时常用 |
| 创建签名密钥 | `identity/oidc/key/<name>` | 关注 `rotation_period` 与 `verification_ttl` |
| 创建 ID Token Role | `identity/oidc/role/<name>` | `template`、`ttl`、`client_id`、`key` |
| 让当前 Entity 签 token | `identity/oidc/token/<role>` | 只能为请求者自己的 Entity 签 |
| 验证 token（脱离 Vault） | `…/identity/oidc/.well-known/openid-configuration` & `…/.well-known/keys` | 无需鉴权 |
| 验证 token（在线） | `identity/oidc/introspect` | 需要 Vault Token |
| 创建 OIDC client（RP） | `identity/oidc/client/<name>` | 默认 `assignments=[]` → 谁都进不来 |
| 把白名单装上 | `identity/oidc/assignment/<name>` | `entity_ids` + `group_ids` |
| 看 Provider Discovery | `identity/oidc/provider/<name>/.well-known/openid-configuration` | 无需鉴权 |
| 激活去重（1.19+，**不可逆**） | `sys/activation-flags/force-identity-deduplication/activate` | 只在 primary 执行 |

---

## 7. 与其它章节的衔接

- **[2.5 身份实体](/ch2-identity-entity)**：本节是它的"引擎入口与
  API 视角"补全。概念在那一节，操作在这一节。
- **[3.1 机密引擎概览](/ch3-secrets-engines)** & **[3.4 Cubbyhole](/ch3-cubbyhole)**：
  `identity/` 是"内置不可拆"特殊引擎家族的第二位成员，把 §1 的对比
  表记牢即可。
- **[4 / 7.1–7.8 认证方法](/)**：每一种 auth method 登录成功后，
  Vault 自动写到 `identity/` 的 entity-alias 就是本节 §2 那张表里的
  操作；理解本节有助于诊断"为什么我同一个人登录两次拿到了两个
  Entity"。
- **[7.11 / 7.12 Vault 作为 OIDC Provider](/)**：本节 §4 给的"引擎
  侧基础"，那两节给"端到端 SSO 实战"。
- **[5.7 Mount Migration](/ch5-mount-migration)**：迁移 auth mount
  时身份归并不会断的原因（accessor 不变）就是本节 §2.1 那条规律。

---

## 8. 互动实验

本节配套的实验在一个 Dev 模式 Vault（1.19.2）上把上述要点全部跑过一
遍：

- **Step 1**：观察 `identity/` 默认挂载、亲手撞它的"三不允许"
  （disable / move / 二次 enable；tune 是允许的），并用 API 把
  Entity / Alias / Group 三类对象的 CRUD 走一遍——含同一 Entity
  跨两个 auth mount 的归并演示。
- **Step 2**：搭出 Identity Tokens 的最小可工作链路：建一把 named key、
  建一个带 template 的 role、签出一条 JWT，用 `jq` 解 payload 看
  `iss/sub/aud` 与你自定义的字段，再分别用 JWKS 端点和
  `identity/oidc/introspect` 两种姿势验证。
- **Step 3**：用 default provider + default key 启用 OIDC IdP 的最小
  配置：建 userpass 用户、建 client（先**不**配 assignments 验证"默
  认全拒"，再加 `allow_all` 修复），拿 Discovery 文档，并用 curl 模
  拟 RP 调用 token 端点跑一次 Authorization Code Flow（用 Vault CLI
  辅助拿 `code`）。
- **Step 4**：体验 `force-identity-deduplication` 激活流程——先在干净
  集群上演示激活 API 与不可逆语义；然后重启 Vault 启用
  `raw_storage_endpoint`，用 `sys/raw` + Python 脚本往存储里**故意注入
  一个同名 entity**（绕过 API 层的去重校验），通过 seal/unseal 分两个
  阶段观察：flag 未激活时只打 `DUPLICATES DETECTED` 警告，激活后自动
  重命名重复 entity 为 `bob-<uuid>`。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-identity" title="实验：Identity 机密引擎与 OIDC Provider 全流程" />
