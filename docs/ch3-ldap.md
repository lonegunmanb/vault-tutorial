---
order: 310
title: 3.10 LDAP 机密引擎：托管目录账号的密码轮转、动态创建与借出归还
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.10 LDAP 机密引擎：托管目录账号的密码轮转、动态创建与借出归还

> **核心结论**：LDAP 机密引擎（`ldap/`）让 Vault 成为**目录服务的密码管家**——
> 通过一个高权限管理员 DN（`binddn`），Vault 拿到了"修改其它账号密码"和"创建/删除账号"
> 的能力。在此之上引擎封装了三种使用模式：
> **Static Roles**（"账号长寿、密码周期轮转"）、
> **Dynamic Roles**（"账号短寿、用完即删"）、
> **Library Sets**（"账号池借出归还，每次借都换新密码"）。
> 这一节把三种模式的形状、生命周期、所需 LDAP 权限以及与 [2.3 Lease](/ch2-lease)、
> [3.3 AWS](/ch3-aws)、未来 [7.X LDAP 认证方法](/) 的边界关系一次讲清。

参考：
- [LDAP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ldap)
- 同模型对照：[3.3 AWS 动态凭据](/ch3-aws)
- 易混区分：未来 7.X LDAP 认证方法（让 LDAP 用户登录 Vault，反向流向）

---

## 1. 一句话定位：Vault 操作 LDAP，而不是 LDAP 用户登录 Vault

凡涉及 "Vault + LDAP" 的需求，先做一道单选题：

| 你的场景 | 该用什么 |
| --- | --- |
| AD/OpenLDAP 里的工程师，希望用 LDAP 账号登录 Vault | **LDAP 认证方法**（`auth/ldap`，未来 7.X） |
| Vault 替我管理目录里某些**服务账号的密码**（轮转、创建、回收） | **LDAP 机密引擎**（本章） |

两者**完全不同方向**：认证方法是"目录账号 → Vault Token"（入站），机密引擎是"Vault → 目录账号"
（出站）。本章只讲后者。

LDAP 机密引擎兼容三种"目录方言"（schema），由 `vault write ldap/config schema=…` 决定：

| schema 值 | 适用目标 | 改密时操作的目标 |
| --- | --- | --- |
| `openldap`（默认） | OpenLDAP / 389DS 等开源 LDAP | `userPassword`（也可挂在 `organization`、`organizationalUnit`、`inetOrgPerson`、`person`、`posixAccount` 等 objectClass 上） |
| `ad` | Microsoft Active Directory | `unicodePwd`（AD 服务端只允许通过加密通道修改，连接必须用 `ldaps://`） |
| `racf` | IBM Resource Access Control Facility | 由插件按 RACF 模式处理；通过 `credential_type=phrase` 可切换为 password phrase |

> 实验只覆盖纯开源的 `openldap`。AD 仅在概念层提及（需要 LDAPS 通道与一台 Active Directory 域控，
> 超出免费实验环境能力；插件本身用 simple bind，不需要 Kerberos）。
> RACF 是 IBM z/OS 大型机产品，没有可供学习的开源版本，本章不展开。

---

## 2. 工作原理：一个管理员 binddn + 三种模式

### 2.1 基础角色

Vault 启用 `ldap/` 引擎后必须先 `vault write ldap/config` 写入：

| 字段 | 含义 |
| --- | --- |
| `url` | LDAP 服务器地址，如 `ldap://host:389` 或 `ldaps://host:636`；可传逗号分隔的多个 URL，Vault 会按顺序尝试实现 failover |
| `binddn` | Vault 操作目录时使用的管理员 DN（如 `cn=admin,dc=example,dc=org`） |
| `bindpass` | 该 DN 的密码 |
| `userdn` | 搜索/修改账号的 base DN（一般是放服务账号的 OU） |
| `userattr` | 搜账号时匹配的属性；不填时默认值随 `schema` 变：`openldap` → `cn`、`ad` → `userPrincipalName`、`racf` → `racfid` |
| `schema` | `openldap`/`ad`/`racf`，影响改密时操作的目标属性 |
| `starttls` | 在只开放 389 端口、又要求加密的环境设为 `true`：Vault 先明文连接再发送 StartTLS 指令升级为加密信道 |

> **轮转 binddn 自身的密码**：调用 `vault write -f ldap/rotate-root` 让 Vault 生成一个新随机密码、
> 写回 LDAP，并在 Vault 内部存储里同步更新。完成后这个新密码**只存在于 Vault 内部**，
> 任何 API 都**不能再把它读出来**（官方原话：*will only be known to Vault and will not be retrievable once rotated*）——
> 后续所有目录操作都由 Vault 在内部代为完成。强烈建议在 `ldap/config` 写入后立刻执行一次。

> **Self-managed vs Root-managed（两种 Static Role 托管模型）**：上表默认描述的是 **Root-managed** 模型——
> Vault 拿高权 `binddn` 代改别人的密码；另一种 **Self-managed** 模型下每个 static role 用自己的凭证修改自己的密码，
> `ldap/config` 不需填 `bindpass`，但创建 role 时必须填 `password` 字段。Self-managed **限 Vault Enterprise**，
> 本章实验只覆盖 Root-managed。

### 2.2 三种模式同框对比

| 模式 | Vault 干什么 | 谁创建账号 | 密码动作 | 账号生命周期 |
| --- | --- | --- | --- | --- |
| **Static Roles** | 周期性"修改密码"操作 | LDAP 管理员预先创建 | 按 `rotation_period` 定时重置 | 长期，密码轮转，应用读"当前密码" |
| **Dynamic Roles** | 按 LDIF 模板新建账号、Lease 到期时按删除 LDIF 销毁 | Vault 现场创建 | 创建时随机生成，无再次轮转 | 短暂（Lease TTL），自动清理 |
| **Library Sets** | 在固定账号池内借出/归还，归还时轮转密码 | LDAP 管理员预先创建 | check-out 时把当前密码交给借用人；check-in 时由 Vault 自动轮转，使旧密码立即失效 | 长期账号，每次借用绑一个 token |

---

## 3. Static Roles：长寿账号 + 周期轮转

![static-role-rotation](/images/ch3-ldap/static-role-rotation.png)

适合场景：**应用配置里只能配一个固定的服务账号**（很多老旧 ETL、备份脚本、CI/CD agent），
但安全要求密码必须定期轮转。

```bash
vault write ldap/static-role/etl-app1 \
  username="app1" \
  dn="cn=app1,ou=ServiceAccounts,dc=example,dc=org" \
  rotation_period="24h"
```

应用只需读 `ldap/static-cred/etl-app1` 拿到当前密码即可（最好每次启动都读一次，
而不是缓存到自己的配置文件里）。

**注意 1**：确认下一次轮转时间时，不要只看 `rotation_period`，要读回 role 的
`next_vault_rotation`。如需立刻换掉当前密码，调用 `vault write -f ldap/rotate-role/etl-app1`
手动轮转即可。

**注意 2**：Static Role 不签发 Lease——读到的密码不会"过期"，只会被下一次轮转覆盖。
和 [2.3 Lease](/ch2-lease) 的动态凭据语义完全不同。

**注意 3**：`vault delete ldap/static-role/etl-app1` 删除的是 Vault 里的 static role 配置，
不要假设它会顺手轮转那个 LDAP 账号的密码。以下为**本文提出的实践建议（非官方原文）**：要么先 `vault write -f ldap/rotate-role/etl-app1` 把密码换成只有 Vault 才知道的随机串再删，
要么在 LDAP 端立即收回该账号的访问权限——否则删 role 那一刻，最后一次发放的密码就成了
"任何拿到过它的人都能继续用"的孤儿凭据。

**注意 4 / 存量账号接管：`skip_import_rotation`**。上面那条 `vault write` 默认会在创建 role 的那一瞬间
立刻把 `app1` 在 LDAP 里的**现有密码**轮成 Vault 生成的随机串。应用如果还没改造成从 Vault 读密码，
在 role 创建之后下一次认证就会被拒。存量迁移场景必须联同 `skip_import_rotation=true` 一起下发：

```bash
vault write ldap/static-role/etl-app1 \
  username="app1" dn="cn=app1,ou=ServiceAccounts,dc=example,dc=org" \
  rotation_period="24h" skip_import_rotation=true
```

这样 Vault 建立了管理关系但不动现有密码；等应用上线从 `ldap/static-cred/etl-app1` 读密码后，
再 `vault write -f ldap/rotate-role/etl-app1` 手动踢一脚、切断旧密码生命周期。可在 `ldap/config` 上
用 `skip_static_role_import_rotation=true` 把这个默认值反转为全局不覆写。

**AD 业主请多注意**：Active Directory 服务器有个叫“lifetime period of an old password”的设置——
密码被 Vault 轮转后的一段宽限期内，旧密码仍然可以登录。这主要是为了容忍多域控之间的密码复制延迟，
**是 AD 的特性，不是 Vault 轮转失败**；审计看到"旧密码仍能认证成功"之前先去 AD 端查这个设置。

---

## 4. Dynamic Roles：用完即删

![dynamic-role-lifecycle](/images/ch3-ldap/dynamic-role-lifecycle.png)

适合场景：**应用每次启动都能动态读凭据**、并且需要"使用完毕、痕迹彻底消失"。

每个 Dynamic Role 由若干段 LDIF 模板定义：

- `creation_ldif`：申领时执行的"创建账号"操作（含 `objectClass`、`userPassword` 等）
- `deletion_ldif`：Lease 到期时执行的"删除账号"操作
- `rollback_ldif`（**官方强烈推荐**）：`creation_ldif` 中途失败时执行的回滚 LDIF，
  避免目录里残留半成品账号——任何一步出错都自动按这段 LDIF 清理掉前面已创建的内容

模板可以引用 `.Username`、`.Password` 这类变量；完整写法见下方 `username_template` 示例。

```bash
vault write ldap/role/web-api \
  creation_ldif=@/tmp/creation.ldif \
  deletion_ldif=@/tmp/deletion.ldif \
  rollback_ldif=@/tmp/rollback.ldif \
  default_ttl="1h" \
  max_ttl="24h" \
  username_template="v_{{.RoleName}}_{{unix_time}}"
```

申领：

```bash
vault read ldap/creds/web-api
# Key                   Value
# ---                   -----
# lease_id              ldap/creds/web-api/abc...
# lease_duration        1h
# lease_renewable       true
# distinguished_names   [cn=v_web-api_1714125600,ou=users,dc=example,dc=org]
# username              v_web-api_1714125600
# password              <随机 64 位>
```

`distinguished_names` 是与 `creation_ldif` 中每条 LDIF 语句一一对应的 DN 数组，供下游做反查或审计定位。

应用使用完后调 `vault lease revoke <lease_id>`，Vault 立刻按 `deletion_ldif` 删账号；
如果忘记 revoke，Lease TTL 到达时也会自动清理。

> 这与 [3.3 AWS 引擎](/ch3-aws) 的 IAM User 动态凭据**完全同模型**——只是清理对象从 IAM User 变成 LDAP entry。

---

## 5. Library Sets：服务账号池"借书还书"

![library-checkout-flow](/images/ch3-ldap/library-checkout-flow.png)

适合场景：**Break-Glass / 应急运维 / SRE on-call**——一个固定账号池子（如 `svc-ops-1/2/3`），
任何时刻只有少数人"持有"，借出期间其他人借不到，还回来时密码自动改掉。

```bash
vault write ldap/library/break-glass-team \
  service_account_names="svc-ops-1,svc-ops-2,svc-ops-3" \
  ttl="2h" \
  max_ttl="4h" \
  disable_check_in_enforcement=false
```

借出：

```bash
vault write -f ldap/library/break-glass-team/check-out
# Key            Value
# ---            -----
# lease_id       ldap/library/break-glass-team/check-out/...
# password       <Vault 现场生成的新密码>
# service_account_name svc-ops-1
```

借出（check-out）动作的不变量：

1. **挑一个 `available=true` 的账号**，标记为 `available=false`
2. **把该账号当前的密码**（也就是上一次 check-in 时新轮转出的那串）作为 Lease 的 `data` 返回给借用人
3. 与借用人的 Vault Token / Entity 绑定——**只有同一个 Token / Entity 能 check-in**（`disable_check_in_enforcement=false` 时）
4. 起 Lease 计时（受 set 上的 `ttl` / `max_ttl` 约束）

归还（check-in 或 Lease 到期）的不变量（这是官方明确写明的核心动作）：

1. **轮转该账号的 LDAP 密码**为一个全新的随机字符串——借用人手里那份密码立刻失效
2. 标记为 `available=true`
3. 等待下一个借用人

> Library 与 Static Role 的差异：Static 是"一个账号长期一个密码、定时轮转"；Library 是
> "一个账号被一个人**短期独占**，每次易主都换密码"。前者关心"过去是否泄露"，后者关心"借出期间是否唯一"。

### 5.1 池子卡死怎么救：管理员强制归还

如果开了 `disable_check_in_enforcement=false`（默认），但借用人的 Token 意外失效、机器崩了，
该账号在 Lease 超时前谁都 `check-in` 不了。这时走管理员专用路径强制归还：

```bash
# 需要在 ldap/library/manage/break-glass-team/check-in 上有 update 权限
vault write -f ldap/library/manage/break-glass-team/check-in \
  service_account_names="svc-ops-1"
```

官方定义：the `manage` endpoint 绕过身份一致性校验，并同样会触发一次密码轮转——
这条路径只应给 highly privileged Vault users（Vault operator）开。

---

## 6. 一表速查：三种模式如何选

| 我有这个需求 → | 选这个 |
| --- | --- |
| 账号必须长期存在（应用配置里写死了），但密码必须定期轮转 | **Static Role** |
| 应用启动时动态拿凭据，用完即删，不留痕迹 | **Dynamic Role** |
| 多个运维共享几个高权账号，借出期间排他，归还瞬间换密码 | **Library Set** |
| AD 域账号需要密码轮转 | Static / Library（设 `schema=ad`；AD 端只允许加密通道改 `unicodePwd`，连接必须 `ldaps://`） |
| 老旧脚本只能 hardcode 密码 | 不要用本引擎，用 [2.7 Response Wrapping](/ch2-response-wrapping) 单次投递 |

---

## 7. 路径与权限快速查阅

| 操作 | 路径 | Policy 示例 |
| --- | --- | --- |
| 启用 / 禁用引擎 | `sys/mounts/ldap` | `capabilities = ["create","read","update","delete"]` |
| 配置连接 | `ldap/config` | `capabilities = ["create","read","update"]` |
| 轮转 binddn 自身 | `ldap/rotate-root` | `capabilities = ["update"]` |
| Static Role CRUD | `ldap/static-role/<name>` | `capabilities = ["create","read","update","delete","list"]` |
| 读 Static 当前密码 | `ldap/static-cred/<name>` | `capabilities = ["read"]` |
| 手动轮转 Static Role | `ldap/rotate-role/<name>` | `capabilities = ["update"]` |
| Dynamic Role CRUD | `ldap/role/<name>` | `capabilities = ["create","read","update","delete","list"]` |
| 申领 Dynamic 凭据 | `ldap/creds/<name>` | `capabilities = ["read"]` |
| Library Set CRUD | `ldap/library/<name>` | `capabilities = ["create","read","update","delete","list"]` |
| Library 借/还 | `ldap/library/<name>/check-out` `check-in` `status` | `capabilities = ["update","read"]` |
| Library 管理员强制归还 | `ldap/library/manage/<name>/check-in` | `capabilities = ["update"]` |

**Vault binddn 在 LDAP 端需要的权限**：

| 模式 | LDAP 权限要求 |
| --- | --- |
| Static / Library | 修改目标 OU 下账号的 `userPassword`（OpenLDAP）/`unicodePwd`（AD） |
| Dynamic | 在指定 OU 下 `add` / `delete` 账号 |

---

## 8. 与其它章节的关系

```
[2.3 Lease]  ── Dynamic / Library 的 TTL & 自动清理
     │
[3.3 AWS 引擎] ── 同模型："Vault → 外部系统签发短期凭据"
     │
[3.10 LDAP 引擎] ◄── 你在这儿
     │
[未来 7.X LDAP Auth] ── 反向："LDAP 用户 → 登录 Vault"
```

---

## 9. 四个最容易踩的坑

1. **AD 改密必须走加密连接** —— Active Directory 服务端规则：`unicodePwd` 只接受受保护通道上的修改。
  在 Vault 使用 simple bind 的常见场景里，优先用 `ldaps://`；如果环境走 389 端口，也要配置 StartTLS 这类 TLS 保护。
  纯明文 `ldap://` 上的"我改密总是失败"大概率是这个问题。这与 Vault 无关，是 AD 端的硬约束。

2. **多行 `creation_ldif` 不要直接 inline** —— 多行 LDIF 直接拼进 `vault write` 命令行容易被换行符切断。
   建议用 `@/tmp/creation.ldif` 让 Vault 读文件，或先 `base64 -w0` 编码后传入（API/CLI 都支持 base64 形式）。

3. **Library `disable_check_in_enforcement=true` 要慎用** —— 默认只有"借的人"能还，
   防止 A 借了 B 给还回去。设为 `true` 后任何 Token 都能 check-in，仅用于运维 Break-Glass 场景。

4. **LDAP 引擎不会替你 hash 密码** —— 引擎直接把生成的明文密码写进目标属性，落盘是否哈希取决于 LDAP 服务端。
   生产环境务必在 OpenLDAP 端启用 `ppolicy` 并打开 `olcPPolicyHashCleartext: TRUE`，否则
   你的服务账号密码会以明文形式留在目录里。

---

## 参考文献

- [LDAP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ldap)
- [Set up the LDAP secrets plugin](https://developer.hashicorp.com/vault/docs/secrets/ldap/setup)
- [Use dynamic credentials with LDAP](https://developer.hashicorp.com/vault/docs/secrets/ldap/dynamic-credentials)
- [Create a service account library](https://developer.hashicorp.com/vault/docs/secrets/ldap/account-library)
- [Cookbook：rotate / delete static roles, account-library check-out / check-in / extend / revoke, hash passwords](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [OpenLDAP Admin Guide](https://www.openldap.org/doc/admin26/)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-ldap"/>
