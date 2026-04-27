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
> [3.3 AWS](/ch3-aws-engine)、未来 [7.X LDAP 认证方法](/) 的边界关系一次讲清。

参考：
- [LDAP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ldap)
- 同模型对照：[3.3 AWS 动态凭据](/ch3-aws-engine)
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

| schema 值 | 适用目标 | 改密时调用的 attribute |
| --- | --- | --- |
| `openldap`（默认） | OpenLDAP / 389DS 等开源 LDAP | `userPassword` |
| `ad` | Microsoft Active Directory | `unicodePwd`（强制 LDAPS） |
| `racf` | IBM Resource Access Control Facility | `racfAttributes`（仅企业大型机） |

> 实验只覆盖纯开源的 `openldap`。AD 仅在概念层提及（需要 LDAPS 与 Kerberos，超出免费实验环境能力）。
> RACF 是 IBM z/OS 大型机产品，没有可供学习的开源版本，本章不展开。

---

## 2. 工作原理：一个管理员 binddn + 三种模式

### 2.1 基础角色

Vault 启用 `ldap/` 引擎后必须先 `vault write ldap/config` 写入：

| 字段 | 含义 |
| --- | --- |
| `url` | LDAP 服务器地址，如 `ldap://host:389` 或 `ldaps://host:636` |
| `binddn` | Vault 操作目录时使用的管理员 DN（如 `cn=admin,dc=example,dc=org`） |
| `bindpass` | 该 DN 的密码 |
| `userdn` | 搜索/修改账号的 base DN（一般是放服务账号的 OU） |
| `schema` | `openldap`/`ad`/`racf`，影响改密时调用的 LDAP 属性 |

> **轮转 binddn 自身的密码**：调用 `vault write -f ldap/rotate-root` 让 Vault 生成一个新随机密码、
> 写回 LDAP、并把 `bindpass` 在 Vault 内更新——之后**连 Vault 自己都不知道原密码是什么**。
> 强烈建议在 `ldap/config` 写入后立刻执行一次。

### 2.2 三种模式同框对比

| 模式 | Vault 干什么 | 谁创建账号 | 密码动作 | 账号生命周期 |
| --- | --- | --- | --- | --- |
| **Static Roles** | 周期性"修改密码"操作 | LDAP 管理员预先创建 | 按 `rotation_period` 定时重置 | 长期，密码轮转，应用读"当前密码" |
| **Dynamic Roles** | 按 LDIF 模板新建账号、Lease 到期时按删除 LDIF 销毁 | Vault 现场创建 | 创建时随机生成，无再次轮转 | 短暂（Lease TTL），自动清理 |
| **Library Sets** | 在固定账号池内借出/归还，借出时改密码 | LDAP 管理员预先创建 | 借出瞬间生成新密码、归还瞬间再生成新密码 | 长期账号，每次借用绑一个 token |

---

## 3. Static Roles：长寿账号 + 周期轮转

适合场景：**应用配置里只能配一个固定的服务账号**（很多老旧 ETL、备份脚本、CI/CD agent），
但安全要求密码"再也不能不变"。

```bash
vault write ldap/static-role/etl-app1 \
  username="app1" \
  dn="cn=app1,ou=ServiceAccounts,dc=example,dc=org" \
  rotation_period="24h"
```

应用只需读 `ldap/static-cred/etl-app1` 拿到当前密码即可（最好每次启动都读一次，
而不是缓存到自己的配置文件里）。

**注意 1**：`rotation_period` 修改对**已存在 role** 不会立刻"重新计时"——
Vault 按现有计划完成下一次轮转后才会按新周期走。如要立即按新周期生效，
删除 role 重建即可。

**注意 2**：Static Role 不签发 Lease——读到的密码不会"过期"，只会被下一次轮转覆盖。
和 [2.3 Lease](/ch2-lease) 的动态凭据语义完全不同。

---

## 4. Dynamic Roles：用完即删

适合场景：**应用每次启动都能动态读凭据**、并且需要"使用完毕、痕迹彻底消失"。

每个 Dynamic Role 由两段 LDIF 模板定义：

- `creation_ldif`：申领时执行的"创建账号"操作（含 `objectClass`、`userPassword` 等）
- `deletion_ldif`：Lease 到期时执行的"删除账号"操作

模板可以用占位符 `{{.Username}}`、`{{.Password}}`，Vault 会按 `username_template` 生成账号名。

```bash
vault write ldap/role/web-api \
  creation_ldif=@/tmp/creation.ldif \
  deletion_ldif=@/tmp/deletion.ldif \
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
# username              v_web-api_1714125600
# password              <随机 64 位>
```

应用使用完后调 `vault lease revoke <lease_id>`，Vault 立刻按 `deletion_ldif` 删账号；
如果忘记 revoke，Lease TTL 到达时也会自动清理。

> 这与 [3.3 AWS 引擎](/ch3-aws-engine) 的 IAM User 动态凭据**完全同模型**——只是清理对象从 IAM User 变成 LDAP entry。

---

## 5. Library Sets：服务账号池"借书还书"

![library-checkout-flow](/images/ch3-ldap/library-checkout-flow.png)

> TODO 绘图提示词:
> ```
> 手绘卡通风格，类似儿童绘本插画。画面中心是一个图书馆借书前台，柜台上立着三本一模一样的硬皮书，
> 书脊分别贴着 svc-ops-1 / svc-ops-2 / svc-ops-3 的标签。
> 一位戴眼镜、围着围裙的图书管理员（代表 Vault）站在柜台后面，手里拿着一把崭新的金钥匙，正要把其中一本书递给前面排队的第一个读者。
> 第一个读者（代表"借用人 A"）伸手接书，手腕上系着一根红色绳子（代表 Vault Lease），绳子另一头连着柜台。
> 后面排队的两个读者（B、C）正眼巴巴看着剩下的两本书。
> 柜台旁立一块小黑板，上面写着 "RETURNED → ROTATE PASSWORD"。
> 背景：高高的书架、挂着 "Library Set: break-glass-team" 的招牌。
> 整体颜色温暖明亮（米黄、淡橙、淡蓝），线条手绘感强，关键英文短词写在画面元素上。
> 中文不出现在画面里，只通过图像隐喻"借书—系绳—归还时换新钥匙"的流程。
> ```

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

借出动作的不变量：

1. **挑一个 `available=true` 的账号**，标记为 `available=false`
2. **修改它的 LDAP 密码**为一个全新的随机字符串
3. 把这个密码作为 Lease 的"data" 返回给借用人
4. 与借用人的 Vault Token 绑定——**只有同一个 Token 能 check-in**（`disable_check_in_enforcement=false` 时）

归还（或 Lease 到期）的不变量：

1. **再次修改密码**——保证借用人手里那份密码立刻失效
2. 标记为 `available=true`
3. 等待下一个借用人

> Library 与 Static Role 的差异：Static 是"一个账号长期一个密码、定时轮转"；Library 是
> "一个账号被一个人**短期独占**，每次易主都换密码"。前者关心"过去是否泄露"，后者关心"借出期间是否唯一"。

---

## 6. 一表速查：三种模式如何选

| 我有这个需求 → | 选这个 |
| --- | --- |
| 账号必须长期存在（应用配置里写死了），但密码不能不变 | **Static Role** |
| 应用启动时动态拿凭据，用完即删，不留痕迹 | **Dynamic Role** |
| 多个运维共享几个高权账号，借出期间排他，借/还瞬间换密码 | **Library Set** |
| AD 域账号需要密码轮转 | Static / Library（设 `schema=ad`，必须 LDAPS） |
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
| Dynamic Role CRUD | `ldap/role/<name>` | `capabilities = ["create","read","update","delete","list"]` |
| 申领 Dynamic 凭据 | `ldap/creds/<name>` | `capabilities = ["read"]` |
| Library Set CRUD | `ldap/library/<name>` | `capabilities = ["create","read","update","delete","list"]` |
| Library 借/还 | `ldap/library/<name>/check-out` `check-in` `status` | `capabilities = ["update","read"]` |

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

## 9. 三个最容易踩的坑

1. **AD 必须 LDAPS** —— Active Directory 的 `unicodePwd` 属性只能通过加密通道修改。
   `ldap://` 上的"我修改一切都失败" 99% 是这个问题。

2. **`creation_ldif` 必须 base64 或 `@file`** —— 多行 LDIF 直接传给 `vault write` 会被换行符吃掉。
   要么用 `@/tmp/creation.ldif` 让 Vault 读文件，要么手动 `base64 -w0` 编码后再传。

3. **Library `disable_check_in_enforcement=true` 要慎用** —— 默认只有"借的人"能还，
   防止 A 借了 B 给还回去。设为 `true` 后任何 Token 都能 check-in，仅用于运维 Break-Glass 场景。

---

## 参考文献

- [LDAP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/ldap)
- [LDAP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/ldap)
- [OpenLDAP Admin Guide](https://www.openldap.org/doc/admin26/)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-ldap"/>
