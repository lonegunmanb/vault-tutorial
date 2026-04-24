---
order: 25
title: 2.5 身份实体（Identity Entity）：打通多维度认证源的元数据中心
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.5 身份实体（Identity Entity）：打通多维度认证源的元数据中心

> **核心结论**：2.4 章节里 Token 是"鉴权凭据"，但 Token 本身**不持久、
> 不带身份**——同一个人通过不同 auth method 登录会拿到完全不同的 token，
> 之间没有任何关联。Identity Entity 是 Vault 在 Token 之上加的**持久身份层**：
> 它把"同一个人在 GitHub / LDAP / userpass 上的多个登录"归并到**同一个
> Entity**，并把策略与组成员关系挂在 Entity 上。这样既保留了 token 的
> 鉴权高速路径，又获得了"按真实身份做治理"的能力。

参考：
- [Identity — Concepts](https://developer.hashicorp.com/vault/docs/concepts/identity)
- [Identity Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/identity)

---

## 1. 为什么需要 Entity：Token 的两个先天不足

回顾 2.4：

- 每次 `vault login` 产物是一条**全新的、孤立的** service token；
- token 上有 `display_name` 等"户籍信息"，但**没有跨登录的稳定 ID**；
- 同一个人今天用 GitHub 登、明天用 LDAP 登，得到的是两条无关 token，
  策略要分别在两个 auth method 上配两遍。

这在小规模时可以忍，规模一大就两个硬伤：

1. **无法聚合统计**："上个月 alice 一共触发了多少次机密读取？"——
   token 维度根本回答不了，因为她每天换无数 token。
2. **策略管理重复**：alice 的权限要在 userpass、GitHub、LDAP 三处各
   维护一份，且永远不一致。

文档对 Identity 的定位写得非常直接：

> The idea of Identity is to maintain the clients who are recognized by Vault.

也就是说——Vault 需要一个**比 token 寿命更长、跨认证方法稳定**的"客户
身份"概念。Entity 就是这个概念，它的作用域是**整个 Vault 集群**，不会
随 token 过期而消失。

---

## 2. Entity 与 Alias：一对多的"身份归并"模型

文档给出的核心模型只有两个对象：

> Each entity is made up of zero or more aliases.
> An entity cannot have more than one alias for a particular authentication backend.

形式化画出来：

```
                +----------------------+
                |  Entity: alice       |
                |  id: ent-abc123      |
                |  policies: [eng]     |
                |  metadata: {...}     |
                +----------+-----------+
                           |
        +------------------+------------------+
        |                  |                  |
+---------------+   +--------------+   +---------------+
| Alias         |   | Alias        |   | Alias         |
| name: alice   |   | name: alice  |   | name: a@x.com |
| mount: github |   | mount: ldap  |   | mount: oidc   |
+---------------+   +--------------+   +---------------+
```

几条不变量：

- **Entity ↔ Alias 是 1 对 N**——一个 alice 可以挂任意多个外部账号；
- **同一个 auth mount 上 Entity 只能挂一个 alias**——你不能在同一个
  GitHub 挂载下把 alice 和 bob 的 GitHub 账号都挂到同一个 Entity；
- **跨 mount 没有这个限制**——所以两个不同 GitHub 挂载（例如分别对
  接两个 GitHub 组织）下 alice 各有一个 alias，可以归并到同一个 Entity。

### 2.1 Alias 的唯一键：alias name + mount accessor

文档：

> Hence, the alias name in combination with the authentication backend
> mount's accessor, serve as the unique identifier of an alias.

**关键就在 mount accessor**——它是每个 auth method 挂载时分配的稳定
字符串（形如 `auth_userpass_a3b8c1d2`），即使你 disable 后再 enable
同一种 auth，accessor 也会变。所以 Vault 区分"两个不同 userpass 挂
载"靠的是 accessor，而不是路径名。

### 2.2 不同 auth method 的 alias name 来源不同

文档列了一张表，挑几个常见的：

| Auth method | alias name 取自 |
| --- | --- |
| Userpass | username |
| LDAP | username |
| GitHub | GitHub 用户名 |
| Kubernetes | ServiceAccount UID（默认）或 name |
| AWS IAM | Role ID（默认）/ IAM unique ID / Canonical ARN / Full ARN |
| JWT/OIDC | 你在 `user_claim` 里配置的 claim 名（**没有默认值**） |
| TLS Certificate | Subject CN |
| AppRole | Role ID |

注意 OIDC 那一行——**`user_claim` 没有默认值**，必须显式配。这是 OIDC
集成里最容易踩的坑：忘配 `user_claim` 的话，登录会成功但**所有人共享
同一个空 alias**，最终全员被归到同一个 Entity 下，权限全乱。

---

## 3. 隐式 Entity：登录就自动建

文档：

> When a client authenticates via any credential backend (except the
> Token backend), Vault creates a new entity. It attaches a new alias to
> it if a corresponding entity does not already exist.

也就是说——你**根本不需要主动建 Entity**，只要有人通过非 token 的
auth method 登录过一次，Vault 就会自动给他建好一条 Entity + 一条对应
的 alias。这个 Entity 就静静地躺在那里，等你将来给它加策略、加组
成员关系。

两个推论：

1. **Token auth method 是唯一例外**——直接用 `vault token create`
   出来的 token 不带 entity（除非显式用了 `entity_alias` 参数和
   `allowed_entity_aliases` 配置的 token role）。这非常合理：用 token
   工厂直接造 token 本身就不涉及"外部身份"，没有什么可以 alias 的。
2. **同一个人通过两个不同 auth method 登录，会被 Vault 当成两个不同
   的人**——因为 Vault 没办法知道"GitHub 上的 alice 和 LDAP 上的
   alice 是同一个人"，**它只看 (alias name, mount accessor) 这个键**。
   要把它们归并，必须管理员**手工**操作（见 §4）。

文档里那段提示也要记住：

> Entities in Vault do not automatically pull identity information from
> anywhere. It needs to be explicitly managed by operators.
> ... Vault will serve as a cache of identities and not as a source of
> identities.

——Vault 是身份的"二级缓存"，不是身份的"权威源"。权威源永远是外部
（GitHub / LDAP / 公司 IdP），Vault 只负责把跨 auth method 的同一个
人在自己内部串起来做治理。

---

## 4. 手工合并：把多个 alias 挂到同一 Entity

实操路径有两条：

**A. 先创建命名 Entity，再把 alias 挂进去**

```bash
# 1) 建一个空 Entity（policies 可选）
vault write identity/entity name=alice-real policies=eng-policy
ENT_ID=$(vault read -format=json identity/entity/name/alice-real | jq -r .data.id)

# 2) 拿到 userpass mount 的 accessor
USERPASS_ACC=$(vault auth list -format=json | jq -r '."userpass/".accessor')

# 3) 把 userpass 上的 alice 挂到这个 Entity 下
vault write identity/entity-alias \
  name=alice \
  canonical_id=$ENT_ID \
  mount_accessor=$USERPASS_ACC
```

之后 alice 用 userpass 登录得到的 token 上 `entity_id` 字段就是
`$ENT_ID`。

**B. 把已存在的隐式 alias 改挂到目标 Entity**

```bash
# 先列出来找到 alias_id
vault list identity/entity-alias/id

# 改挂
vault write identity/entity-alias/id/<alias_id> canonical_id=$ENT_ID
```

合并完成后的效果：

- alice 通过 userpass 登 / 通过 LDAP 登 / 通过 GitHub 登——**每次得到
  的 token 上 `entity_id` 都是同一个**；
- 审计日志里这些操作可以按 entity_id 聚合统计；
- 所有需要"按真实身份"做的策略（见 §5）只在 Entity 这一处维护，**任
  何 auth method 登的 token 都自动享受**。

### 4.1 注意：一个 mount 上一个 alias 的硬约束

文档反复强调：

> An entity cannot have more than one alias for a particular
> authentication backend.

意思是：在一个 userpass 挂载上，**alice 这个 Entity 只能有一条 alias**。
你不能把 `alice` 和 `alice2` 两个 userpass 用户都归到 `alice-real` 这
个 Entity 下。如果业务上确实需要"alice 在 userpass 里有两个用户名"，
正确做法是 **enable 第二个 userpass 挂载**（路径不同 → mount accessor
不同 → 才能在同一 Entity 下挂第二个 alias）。

---

## 5. Entity Policy：请求时动态求值的"叠加层"

这是 Identity 系统**最核心、也最容易被低估**的能力。

### 5.1 Token 上的 policy ≠ 实际生效的 policy

2.4 章节里我们讲过 token 创建时会冻结一个 `policies` 列表。但有了
Entity 之后，**真正生效的 policy 集合是两部分的并集**：

```
最终 capabilities = policies(token) ∪ policies(entity) ∪ policies(group ∋ entity)
```

文档把这个变化称为一次范式转移：

> This is a paradigm shift in terms of when the policies of the token
> get evaluated. Before identity, the policy names on the token were
> immutable ... But with entity policies, ... **the evaluation of
> policies applicable to the token through its identity will happen at
> request time**.

注意"at request time"——意味着：

- **不需要重新登录**，给 Entity 挂一条新 policy 之后，已经签出去的
  所有关联 token 立刻就有了新权限；
- **不需要等 token 过期**，从 Entity 上摘掉一条 policy 之后，已经签
  出去的所有关联 token 立刻就丢了那部分权限。

这个性质在生产里非常关键——它让"撤权"的延迟从"token TTL（小时级）"
缩短到"修改 entity 的那一刻"。

### 5.2 Entity policy 是"加法"，不是"替换"

文档：

> It is important to note that the policies on the entity are only a
> means to grant additional capabilities and not a replacement for the
> policies on the token.

也就是说——Entity policy **只能加权限，不能减**。你没办法用 entity
policy 收回 token 上已经写死的策略。这个非对称很重要：

- 给某人临时加权 → 改 entity policy（即时生效）
- 给某人临时降权 → **必须 revoke 当前 token 让他重登**（旧 token 上
  的策略冻结在签发时刻，撤不掉）

这也是为什么 2.4 章节里"短 TTL + 强制重登"的设计在生产里仍然重要：
**Entity policy 解决了加权的实时性，但减权依旧依赖 token 过期**。

### 5.3 安全提醒：写 entity 的 API 比想象的危险

文档有一条专门的警告：

> Be careful in granting permissions to non-readonly identity endpoints.
> If a user can modify an entity, they can grant it additional privileges
> through policies. If a user can modify an alias they can login with,
> they can bind it to an entity with higher privileges.

把它翻译成实操结论——`identity/entity/*` 和 `identity/entity-alias/*`
的 write 权限**等价于"可以提权到任意 policy"**。生产 policy 里这两
组路径必须只授给 platform admin / IdP 同步系统这种少数账户，绝对不
能给业务应用。

---

## 6. Identity Group：把策略沿组关系传递

Entity policy 解决了"按个人挂策略"，但实际企业组织有数百到数千个员
工，按人挂策略不可行。Identity Group 提供组维度的策略传递。

### 6.1 内部组：手工管理成员

```bash
# 创建 group "engineering"，挂 eng-policy，包含 alice 和 bob 两个 entity
vault write identity/group \
  name=engineering \
  policies=eng-policy \
  member_entity_ids=$ALICE_ID,$BOB_ID
```

之后 alice / bob 任何 auth method 登录 → 拿到的 token 自动享有
`eng-policy`，无需在 token 或 entity 上做任何改动。

### 6.2 子组：层级继承

文档：

> Entities can be direct members of groups, in which case they inherit
> the policies of the groups they belong to. Entities can also be
> indirect members of groups. For example, if a GroupA has GroupB as
> subgroup, then members of GroupB are indirect members of GroupA.

形式化：

```
Group: company       (policy: company-base)
  ├── Group: engineering   (policy: eng)
  │     ├── Entity: alice
  │     └── Entity: bob
  └── Group: sales         (policy: sales)
        └── Entity: carol
```

alice 最终拿到的 policy 集合 = `token` ∪ `entity(alice)` ∪
`engineering` ∪ `company`。换句话说，公司全员通用的基础权限挂到
`company` 上一次，所有子部门的 entity 都自动继承。

### 6.3 内部组 vs 外部组

| 维度 | 内部组（internal） | 外部组（external） |
| --- | --- | --- |
| 成员管理 | 完全手动 | 半自动，依赖外部组关系 |
| 可以挂 alias 吗 | 不可以（成员是 entity） | **必须挂且只能挂一个 alias** |
| alias 指向 | 无 | 外部 IdP 的某个组（LDAP group / GitHub team / OIDC `groups` claim） |
| 成员变更时机 | 调 API 改 `member_entity_ids` | 该用户**下次 login 或 renew 时**自动同步 |
| 典型场景 | Vault 内部部门、project | "GitHub 组织里的 dev team 自动获得 dev 策略" |

外部组的"半自动"有个文档明确点出的延迟：

> If the user is removed from the group in LDAP, the user will not
> immediately be removed from the external group in Vault. The group
> membership change will be reflected in Vault only upon the subsequent
> login or renewal operation.

——LDAP 那边把 alice 踢出 dev 组之后，alice 在 Vault 这边**还是 dev
组成员**，直到她下次 login/renew 时 Vault 才会重新查 LDAP。这个延迟
在生产里要心里有数：**关键权限收回必须配合显式 token revoke**。

---

## 7. Entity 与 Token 的总览图

```
+--------------------------------------------------------------------+
|                       Identity Store (cluster-wide, persistent)     |
|                                                                     |
|   Group: company (policy=company-base)                              |
|     └── Group: engineering (policy=eng)                             |
|             ├── Entity: alice (policy=alice-personal)               |
|             │     ├── Alias { name=alice, mount=userpass/  }        |
|             │     ├── Alias { name=alice, mount=ldap/      }        |
|             │     └── Alias { name=alice-gh, mount=github/ }        |
|             └── Entity: bob                                         |
|                                                                     |
+----------------------------|-----------------------------------+----+
                             | (alias 命中时，token 上写入 entity_id)
                             v
+--------------------------------------------------------------------+
|                       Token Store (2.4 章)                          |
|                                                                     |
|   Token hvs.xxx { entity_id=ent-alice, policies=[default], ... }    |
|                                                                     |
|   每次 API 请求：                                                    |
|     capabilities = policies(token)                                   |
|                  ∪ policies(entity[entity_id])      ← 请求时动态查    |
|                  ∪ policies(group ∋ entity_id)      ← 请求时动态查    |
+--------------------------------------------------------------------+
```

几个关键关系一眼就能看清：

- Identity Store 是**持久身份层**，跨 token 寿命存在；
- Alias 是 (alias_name, mount_accessor) 这个键到 Entity 的映射，**单向**：
  从 alias 能找到 Entity，但 Entity 上的 policy 变更不会回写 alias；
- Token 上只存一个轻量的 `entity_id` 引用，每次请求时**实时去 Identity
  Store 把 entity policy 和 group policy 求并集**——这就是 §5.1 "at
  request time" 的实现含义。

---

## 8. 实验室预告

本节配套的动手实验把上面五个关键设计跑一遍：

1. **隐式 Entity 与 Alias**：启用 userpass，让 alice 登一次，观察
   Vault 自动建出来的 Entity + Alias，看清 token 上的 `entity_id` 字段；
2. **同一种 auth 在不同 mount 上不会自动合并**：再 enable 一个
   `userpass-corp/` 挂载，让 alice 在那里也建一个用户登录一次——
   得到的是**第二个 entity_id**，因为 mount accessor 不同；
3. **手工合并 Entity**：建一个命名 Entity `alice-real`，把两个 mount
   上的 alias 都改挂到它下面，验证两边登录得到的 token 现在 entity_id
   一致；
4. **Entity policy 请求时叠加**：写一个只有 entity policy 才能读的
   KV，验证"token 上没这条 policy 也能读"；从 Entity 上摘掉 policy 后，
   **不重登**就立刻失能；
5. **Identity Group 与子组继承**：建 `engineering` 组挂 alice，再建
   父组 `company` 把 `engineering` 设为子组——alice 自动获得两层组
   策略的并集。

进入实验前请回顾 §2.1 ((alias_name, mount_accessor) 唯一键)、§5.1
("at request time" 的含义)、§5.2 ("entity policy 只加不减") 这三段。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-identity-entity" title="实验：Entity / Alias / Group 的归并与策略叠加" />

## 参考文档

- [Identity — Concepts](https://developer.hashicorp.com/vault/docs/concepts/identity)
- [Identity Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/identity)
- [Identity: Entities and Groups Tutorial](https://developer.hashicorp.com/vault/tutorials/auth-methods/identity)
- [Client Count](https://developer.hashicorp.com/vault/docs/concepts/client-count)
