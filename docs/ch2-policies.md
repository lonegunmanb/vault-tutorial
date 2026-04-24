---
order: 26
title: 2.6 细粒度策略（Policies）与合规性密码策略（Password Policies）编写指南
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.6 细粒度策略（Policies）与合规性密码策略（Password Policies）编写指南

> **核心结论**：Vault 里有两个**名字相像但完全不相干**的"策略"概念：
> **Policies（ACL 策略）** 决定一个 token 能不能调某条 API 路径，是 Vault
> 的鉴权规则引擎；**Password Policies** 决定 Vault 在替你生成密码时该怎么
> 凑字符，跟 ACL 一点关系也没有。本节把这两个机制各自的语法、求值时机、
> 优先级规则和踩坑点全部讲清。

参考：
- [Policies — Concepts](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [Password Policies — Concepts](https://developer.hashicorp.com/vault/docs/concepts/password-policies)

---

## 1. ACL Policy 的世界观：路径 + 能力 + 默认拒绝

文档开篇那两句必须一字不改地记住：

> Everything in Vault is path-based, and policies are no exception.
> Policies are deny by default, so an empty policy grants no permission
> in the system.

也就是说——

- Vault 把整个系统抽象成一棵 URL 路径树（`secret/`、`auth/`、`sys/`、
  `identity/` …），**每一个 API 操作都对应路径树上的一个节点 + 一个 HTTP
  动词**；
- Policy 就是若干条 (path, capabilities) 的列表，**只能加 allow，不能
  加 deny**（`deny` 这个 capability 是显式的拒绝标记，见 §2）；
- **没明写 = 不允许**——这一句话堵住了所有"我以为它默认能读"的隐患。

最简单的形态：

```hcl
path "secret/foo" {
  capabilities = ["read"]
}
```

挂上这条 policy 的 token，**只能且仅能** `GET secret/foo`，连
`secret/foo/bar` 都看不到。

### 1.1 capabilities 的完整列表

文档给出的 9 个能力，按使用频率排：

| capability | 对应 HTTP | 含义 |
| --- | --- | --- |
| `read` | GET | 读取路径上的数据 |
| `create` | POST/PUT | 在路径上**第一次**写入数据 |
| `update` | POST/PUT | 修改路径上**已存在**的数据 |
| `patch` | PATCH | 部分更新 |
| `delete` | DELETE | 删除 |
| `list` | LIST | 列子路径 |
| `sudo` | — | 通过 root-protected 路径所必需的额外能力 |
| `deny` | — | 显式拒绝，**优先级高于一切** |
| `subscribe` | — | 订阅 events（1.16+） |
| `recover` | — | 从快照恢复（1.18+） |

几个反直觉点必须记住：

- **多数 Vault 路径不区分 create 和 update**——所以你写 `["create"]`
  实际上等同于"啥都不能做"，因为 update 也是必需的。**默认就写
  `["create", "update"]`**；
- `read` 其实是"GET"——动态机密接口（如 `database/creds/<role>`）虽然
  在做"创建一个数据库账号"，但 HTTP 动词是 GET，所以 policy 里要写
  `read` 而不是 `create`。**永远以 HTTP 动词为准**；
- `list` 返回的 key **不会被 policy 二次过滤**——所以**不要把敏感信息
  编进 path 名字**（例如 `secret/payroll/<ssn>` 这种命名），因为有 list
  权限的人能直接看到所有 ssn；
- **`sudo` 不能单独存在**，必须配合 `read` / `update` 等具体能力。它的
  作用是给 sudo-protected 端点（如 `auth/token/accessors`、`sys/raw`、
  `sys/audit`）开门，但开门后还要有具体动作权限才能干活；
- **`deny` 一票否决**——只要某条匹配规则里有 deny，其它 policy 上对同
  一路径的所有 allow 都失效。这个性质在 §3 优先级里要再讲一次。

### 1.2 一个偷懒的快捷键：`-output-policy`

不知道某条命令到底要哪些 capabilities 的话，加 `-output-policy` 就行：

```bash
$ vault kv get -output-policy secret/foo
path "secret/data/foo" {
  capabilities = ["read"]
}
```

这是写新 policy 时的救命稻草——**不要凭感觉猜**，让 CLI 自己告诉你。

---

## 2. 路径匹配：exact / glob `*` / wildcard `+`

文档列了三种 path pattern：

```hcl
# 精确匹配——只能读 secret/foo 这一个路径
path "secret/foo" {
  capabilities = ["read"]
}

# glob ── * 必须出现在路径末尾，匹配任意后缀
path "secret/bar/*" {
  capabilities = ["read"]
}

# wildcard ── + 匹配任意一个 path segment，不跨 / 边界
path "secret/+/teamb" {
  capabilities = ["read"]
}
```

**关键约束**：

- `*` 只能出现在 path 的**最后一个字符**——它不是正则，不能放在中间；
- `+` 是从 1.1 才加的"段通配符"，可以出现在路径任何位置，但**只匹配
  一段**（`/` 之间的内容）；
- glob 是**前缀匹配**——`path "secret/foo*"` 会同时命中
  `secret/foo`、`secret/food`、`secret/foo/bar`，**这往往不是你想要的**。
  要严格限制就用 exact path 或 `secret/foo/*`。

### 2.1 优先级规则——多条 path 都匹配时谁说了算

实际工作里非常常见的场景：root namespace 里有个 `secret/*` 给全员
读，但 `secret/admin/*` 只想给 admin 团队。Vault 的处理方式是**最具体
匹配胜出**，规则按顺序：

1. 第一个 `+` / `*` 出现得越早，优先级越低；
2. 末尾是 `*` 的优先级低于不带 `*` 的；
3. `+` 段更多的优先级低；
4. 路径短的优先级低；
5. 字典序小的优先级低。

也就是说——**给 `secret/admin/*` 加一条 policy 之后，admin 子树下的访
问就走它，不再走通配的 `secret/*`**。这一点跟"取所有匹配项的并集"完全
不同，**只取最高优先级那一条**。

但有个例外：如果**两条 policy 用的是同一条 path pattern**（无论分散
在几个 policy 文件里），它们的 capabilities **取并集**。这就是为什么
你在 entity policy / group policy 里给同一个 path 加权能跟 token policy
叠加的原因——它们最终都被 Vault 摊平成"同 path 多源"。

### 2.2 `deny` 永远赢

文档原话：

> deny — Disallows access. This always takes precedence regardless of
> any other defined capabilities, including sudo.

也就是说——只要你某条匹配规则里出现了 deny，**别的 policy 上对同一路
径写一万个 allow 也没用**。这是 Vault 里**唯一可以"减权"的机制**。

```hcl
# 给全员 secret/* 的读权
path "secret/*" {
  capabilities = ["read"]
}
# 但 secret/super-secret 谁都不能碰
path "secret/super-secret" {
  capabilities = ["deny"]
}
```

注意——deny 必须挂在 token 自身的 policies 里才能用来"压住" token 自
身的其它 policy。前一节 2.5 里讲过，挂在 entity 上的 deny 压不住 token
上原本的 allow，因为 entity policy 是"加法"，**这个加法过程中如果出现
了一条 deny 的同 path 规则，deny 会赢**——但前提是这条 deny 与目标
allow 落在**同一次评估**里。

---

## 3. Parameter Constraints：在 path 之外再卡 HTTP 参数

光控制路径还不够——例如 `auth/userpass/users/*` 这条路径既能改密码
又能改 policy 列表，你想给用户开"自助改密码"功能就必须卡到参数级别。

文档支持 3 个细粒度约束：

```hcl
# 用户只能改自己 userpass 里的密码，不能改 policies / token_ttl 等
path "auth/userpass/users/{{identity.entity.aliases.<acc>.name}}" {
  capabilities = ["update"]
  allowed_parameters = {
    "password" = []
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `required_parameters` | 请求**必须**带这些参数，否则 403 |
| `allowed_parameters` | 请求**只能**带这些参数；`"*" = []` 表示其它参数也允许 |
| `denied_parameters` | 请求**不能**带这些参数；优先级**高于** allowed |

`allowed_parameters` 的 value：

- `[]` — 这个参数允许传，**任意值**；
- `["a", "b"]` — 这个参数只能传 `a` 或 `b`；
- `["foo-*"]` / `["*-bar"]` — 前后缀 glob，但**容易踩坑**（见下文）。

### 3.1 三个必须知道的"边角行为"

文档自己用 "may result in surprising behavior" 警告了下面这些：

1. **KV v2 不支持参数约束**——文档原话："The `allowed_parameters`,
   `denied_parameters`, and `required_parameters` fields are not
   supported for policies used with the version 2 kv secrets engine."
   想给 KV v2 做字段级控制，只能在路径层面（拆 mount 或拆子 path）解
   决；
2. **默认值不会被检查**——如果 API 接口某参数有默认值（例如 `no_store`
   默认 false），用户**不传**这个参数时，policy 引擎"看不到"它，**denied
   value 检查会被绕过**。要堵这个洞必须配合 `required_parameters` 强
   制要求传：

   ```hcl
   path "secret/foo" {
     capabilities      = ["create"]
     required_parameters = ["no_store"]
     denied_parameters   = { "no_store" = [false, "false"] }
   }
   ```

3. **glob 在参数值上同样存在**——`"bar" = ["baz/*"]` 看似只允许
   `baz/quux`，但实际上 `baz/quux,wibble` 这种逗号串也能通过（如果后
   端 API 支持逗号分隔成多值）。**用 glob 限制参数值时一定要审一遍后
   端 API 是不是也接受 list/comma 格式**。

### 3.2 Response Wrapping 强制 TTL

policy 还能强制要求某条路径上的请求**必须**用 response wrapping
（2.7 节会展开）：

```hcl
path "auth/approle/role/my-role/secret-id" {
  capabilities      = ["create", "update"]
  min_wrapping_ttl  = "1s"   # 设了就等于强制必须 wrap
  max_wrapping_ttl  = "90s"
}
```

`min_wrapping_ttl >= 1s` 等于"这条 API 不允许直接返回明文，必须包成一
次性 wrapped response"——AppRole 派 SecretID 的标准生产姿势。

---

## 4. Templated Policies：把 entity 信息拼进 path

很多场景需要"每个用户只能访问自己的子目录"——一万个员工就要写一万
条 policy 吗？文档给的方案是 **templated policy**：

```hcl
# 每个 entity 自己一片 KV 子空间
path "secret/data/{{identity.entity.id}}/*" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}
path "secret/metadata/{{identity.entity.id}}/*" {
  capabilities = ["list"]
}
```

请求评估时，`{{identity.entity.id}}` 会被替换成**当前请求 token 关联
的 entity 的实际 ID**。一份 policy 服务全员，每个人各自被关进自己的
子目录。

### 4.1 可用的 template 变量

文档给了一长串，最常用的几个：

| 变量 | 含义 |
| --- | --- |
| `identity.entity.id` | 当前 entity 的 UUID |
| `identity.entity.name` | entity 的名字（可重命名，**慎用**） |
| `identity.entity.metadata.<key>` | entity 上的某个 metadata |
| `identity.entity.aliases.<mount accessor>.name` | entity 在某 mount 上的 alias 名（例如 username） |
| `identity.entity.aliases.<mount accessor>.metadata.<key>` | alias 的 metadata（例如 K8s SA namespace） |
| `identity.groups.ids.<gid>.name` | 某 group 的名字 |
| `identity.groups.names.<gname>.id` | 某 group 的 ID |

**最佳实践**：模板里**永远用 ID 不用 name**——name 可以改（甚至被回
收复用），改了之后 policy 就指向了别的实体或 group。

### 4.2 一个常用的"用户改自己密码"案例

```hcl
# 把当前 entity 在 userpass mount 上的 alias name（= username）拼进 path
path "auth/userpass/users/{{identity.entity.aliases.auth_userpass_a3b8c1d2.name}}" {
  capabilities       = ["update"]
  allowed_parameters = { "password" = [] }
}
```

效果：alice 登录后，这条 policy 解出来是
`auth/userpass/users/alice`，**只允许她调 update + 只能传 password 字
段**。任何用户都不能改别人的密码 / 改自己的 policies。

注意 `auth_userpass_a3b8c1d2` 是 mount accessor——**写 policy 之前先
`vault auth list` 拿一下**，accessor 不是固定值，每次重新 enable 都会
变。

---

## 5. 内建 policy：`default` 与 `root`

Vault 出厂自带两条 policy：

### 5.1 `default`：人人都有，可改

每次 `vault token create` 默认会附上 `default`。它的内容**不是**官方写
死，而是 Vault 在你第一次启动时种下的一份"安全基线"，**你可以改它，
Vault 永远不会把它覆盖回去**：

```bash
vault read sys/policy/default
```

它默认包含的关键能力：

- `auth/token/lookup-self` / `renew-self` / `revoke-self` —— token 自查、
  自续、自吊；
- `cubbyhole/*` —— 私有 cubbyhole 读写（2.7 节会用到）；
- `sys/wrapping/wrap` / `unwrap` / `lookup` —— response wrapping 操作；
- `sys/tools/random` / `sys/tools/hash` —— 工具类只读端点。

如果业务上**完全不需要 default**（例如一个只用来读特定 KV 的 service
account），创建 token 时加 `-no-default-policy` 就能拒绝它。

### 5.2 `root`：神级权限，不可改不可删

文档原话：

> A root user can do anything within Vault. ... it is highly recommended
> that you revoke any root tokens before running Vault in production.

`root` policy 不能修改、不能删除，挂上它的任何 token 都拥有 Vault 内
的全部权限。**生产环境永远不应该有长期存在的 root token**——临时需要
就 `vault operator generate-root` 多人共同授权一个，用完立刻 revoke。

---

## 6. Token Policy vs Identity Policy 的最终求值公式

把 2.4 / 2.5 / 本节的内容串起来——一次 API 请求时 Vault 真正用来鉴权
的"有效 policy 集合"是：

```
effective_policies(token) = policies_on_token             ← 签发时冻结
                          ∪ policies_on_entity            ← 请求时实时查
                          ∪ policies_on_groups_recursive  ← 沿子组链路
```

注意几个不对称：

- **token 上的 policies 字段**冻结在签发时刻，**修改不了**——要换只
  能 revoke 重登；
- **entity / group 上的 policy 修改即时生效**——下次请求就用新规则；
- **policy 内容本身**修改也是即时生效——文档原话："the contents of
  policies are parsed in real-time whenever the token is used"。

最后一条非常关键——**改 policy 内容比 revoke token 廉价多了**。生产
里发现某条 policy 给多了的话，第一反应不应该是去找哪些 token 持有它
然后 revoke，而是直接改那条 policy 的内容（去掉危险路径），下一次请
求就被拒绝了。

---

## 7. Password Policies：跟 ACL 完全无关的另一套"策略"

文档开篇就把读者拉警惕：

> Note: Password policies are unrelated to Policies other than sharing
> similar names.

Password Policy 是一份**怎么生成密码**的指令——给 Database / LDAP /
PostgreSQL 这些机密引擎在创建账号时用的。**它不参与鉴权**。

### 7.1 语法：长度 + 一组 charset 规则

```hcl
length = 20

rule "charset" {
  charset   = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset   = "0123456789"
  min-chars = 1
}
rule "charset" {
  charset   = "!@#$%^&*"
  min-chars = 1
}
```

效果：长度 20，至少各 1 个大写、小写、数字、特殊字符。注意几条文档
强调的细节：

- **`length` 至少为 4**；
- **必须至少有一条 charset 规则**——只写 `length = 20` 不指定字符集是
  非法的；
- **多条 rule 的 charset 会被去重合并**作为生成时的字符池，但**每条
  rule 自己的 min-chars 仍各自独立检查**；
- **去重合并后字符池长度不能超过 256**。

### 7.2 生成原理与"卡死"风险

文档把生成过程画成了"猜-验"循环：

1. 用密码学安全 RNG 生成 N 个随机数（N = length）；
2. 每个数对当前合并字符池长度取模，挑出对应字符，拼成候选密码；
3. 把候选密码交给所有 rule 验证；
4. 全过 → 返回；任意一条挂了 → 回到步骤 1 重试。

**性能陷阱**：当某条 rule 要求"必须有 1 个来自小字符集的字符"（例
如 `!@#$` 这种 4 字符集）时，生成器要不停重试直到撞中——**rule 越
苛刻、字符集越小，单次生成耗时呈指数级上升**。文档自己有性能曲线图。
建议：**如果业务对密码长度没有强制要求，加长长度反而比加严 rule 更
便宜**——长密码自然更容易满足 min-chars 约束。

### 7.3 默认密码策略

如果机密引擎没显式指定 password policy，Vault 用一份内建的默认
（同时被前面文档展示过）：

```hcl
length = 20
rule "charset" { charset = "abcdefghijklmnopqrstuvwxyz" min-chars = 1 }
rule "charset" { charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" min-chars = 1 }
rule "charset" { charset = "0123456789"                 min-chars = 1 }
rule "charset" { charset = "-"                          min-chars = 1 }
```

注意——默认 policy 把 `-` 当成"特殊字符"。这对绝大多数数据库是 OK
的，但**如果目标系统对 `-` 敏感（比如某些 LDAP DN 解析器）就要写自
己的 password policy 替换掉**。

### 7.4 怎么用

```bash
# 1) 写一份 password policy
vault write sys/policies/password/strict policy=@strict.hcl

# 2) 在机密引擎配置里引用
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  password_policy=strict \
  ...

# 3) 试一把生成结果
vault read sys/policies/password/strict/generate
```

第 3 条是日常调试 password policy 的手段——**先用 generate 端点看效
果，再去配置真实引擎**。

---

## 8. 一张图总览本节所有概念的关系

```
+--------------------------------------------------------------------+
|                  Vault 鉴权决策链 (本节内容)                        |
|                                                                     |
|  HTTP request: GET /v1/secret/data/foo  +  X-Vault-Token: hvs.xxx   |
|                              │                                      |
|                              ▼                                      |
|     ┌────────────────── 鉴权阶段 ────────────────────┐             |
|     │                                                │             |
|     │  effective_policies(token) =                   │             |
|     │      policies_on_token        ← 冻结于签发时   │             |
|     │    ∪ policies_on_entity       ← 请求时实时查   │             |
|     │    ∪ policies_on_groups_∀     ← 沿子组传递    │             |
|     │                                                │             |
|     │  对每条 policy 逐条匹配 path 规则：             │             |
|     │      1. 找出最具体匹配 (优先级 §3)             │             |
|     │      2. 任意 deny → 拒                         │             |
|     │      3. 否则取并集 capabilities               │             |
|     │      4. 检查 capabilities 是否含本次 HTTP verb │             |
|     │      5. 检查 parameter constraints             │             |
|     └────────────────────────────────────────────────┘             |
|                              │                                      |
|                              ▼                                      |
|                           允许 / 拒绝                               |
+--------------------------------------------------------------------+

+--------------------------------------------------------------------+
|              Password Policies — 完全独立的另一套                   |
|                                                                     |
|   database/postgres 引擎生成账号密码时：                             |
|     vault → 加载 password_policy "strict" → 跑生成循环              |
|       length + rule "charset" { ... }  → 候选密码 → 通过 → 返回     |
|                                                                     |
|   ※ 跟上面的鉴权决策链没有任何交集，仅仅名字像                       |
+--------------------------------------------------------------------+
```

---

## 9. 实验室预告

本节配套的动手实验把上面 8 节内容跑一遍：

1. **写一条最小 policy + capabilities 完整体验**：用 `-output-policy`
   反推命令需要什么权限；体验"未授权的路径默认 403"；
2. **路径匹配优先级**：让同一个 token 同时挂 `secret/*` 和
   `secret/admin/*` 两条 policy，验证"具体路径胜出"；再试 `deny` 一
   票否决；
3. **Parameter constraints**：写一条"用户只能改自己 userpass 密码"
   的 policy，验证传 `policies` 字段会被拒；
4. **Templated policy**：写一条 `secret/data/{{identity.entity.id}}/*`
   的 policy，验证 alice 和 bob 互相看不到对方的子目录；
5. **Password Policies**：写一条 strict password policy，调
   `sys/policies/password/<name>/generate` 看生成的密码，对比默认
   policy 的差别。

进入实验前请回顾 §2.1（capabilities 中 create/update 通常要一起写）、
§3.1（KV v2 不支持 parameter constraints）、§4.1（template 永远用 ID
不用 name）这三段。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-policies" title="实验：ACL Policy 与 Password Policy 编写实战" />

## 参考文档

- [Policies — Concepts](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [Password Policies — Concepts](https://developer.hashicorp.com/vault/docs/concepts/password-policies)
- [ACL Policy Path Templating Tutorial](https://developer.hashicorp.com/vault/tutorials/policies/policy-templating)
- [Print Policy Requirements (CLI)](https://developer.hashicorp.com/vault/docs/commands#print-policy-requirements)
