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
| **Library Sets** | 在固定账号池内借出/归还，归还时轮转密码 | LDAP 管理员预先创建 | check-out 时把当前密码交给借用人；check-in 时由 Vault 自动轮转，使旧密码立即失效 | 长期账号，每次借用绑一个 token |

---

## 3. Static Roles：长寿账号 + 周期轮转

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

**注意 3**：`vault delete ldap/static-role/etl-app1` **不会顺手轮转**那个 LDAP 账号的密码。
官方建议要么先 `vault write -f ldap/rotate-role/etl-app1` 把密码换成只有 Vault 才知道的随机串再删，
要么在 LDAP 端立即收回该账号的访问权限——否则删 role 那一刻，最后一次发放的密码就成了
"任何拿到过它的人都能继续用"的孤儿凭据。

---

## 4. Dynamic Roles：用完即删

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
# username              v_web-api_1714125600
# password              <随机 64 位>
```

应用使用完后调 `vault lease revoke <lease_id>`，Vault 立刻按 `deletion_ldif` 删账号；
如果忘记 revoke，Lease TTL 到达时也会自动清理。

> 这与 [3.3 AWS 引擎](/ch3-aws) 的 IAM User 动态凭据**完全同模型**——只是清理对象从 IAM User 变成 LDAP entry。

---

## 5. Library Sets：服务账号池"借书还书"

![library-checkout-flow](/images/ch3-ldap/library-checkout-flow.png)

> TODO 绘图提示词:
> ```
> 手绘卡通风格，类似儿童绘本插画。整张图是一条 5 格分镜漫画，按 "上 3 格 + 下 2 格" 排版：
>   ┌─── 第1格 ───┬─── 第2格 ───┬─── 第3格 ───┐
>   │             │             │             │
>   ├─────────────┴─────────────┼─────────────┤
>   │                           │             │
>   │      第5格        ◄────   │   第4格     │
>   └───────────────────────────┴─────────────┘
> 上排从左到右阅读 (1→2→3)，下排从右到左阅读 (4→5)，整体是一个 "U 形" 故事流。
> 用细黑墨线勾边、暖色填充（米黄、淡橙、淡蓝、奶白）。每两个相邻格之间留出窄窄的 gutter，
> 但 "相邻两格必须有同一个角色横跨 gutter"——同一个人物的身体一半画在前格、一半画在后格，
> 让读者一眼看出 "这就是同一个人继续走到下一幕"。共边角色对应关系：
>   1↔2 共边：VAULT (横跨 gutter)
>   2↔3 共边：READER A (横跨 gutter)
>   3↔4 共边：READER A (纵向跨 gutter，3 在上、4 在下)
>   4↔5 共边：VAULT (横跨 gutter，4 在右、5 在左)
>
> **分格之间的方向箭头**（与 U 形阅读流一致，画在 gutter 中央、用粗黑墨线 + 黄色描边的卡通箭头，
> 箭头上写英文 "NEXT"，避免读者把方向看反）：
>   1→2 箭头：水平向右，画在格 1 与格 2 之间的竖向 gutter 中央
>   2→3 箭头：水平向右，画在格 2 与格 3 之间的竖向 gutter 中央
>   3→4 箭头：竖直向下，画在格 3 与格 4 之间的横向 gutter 中央 (上排到下排的转折，弯成 ⤵ 形 90° 拐角)
>   4→5 箭头：水平向左 (反方向！)，画在格 4 与格 5 之间的竖向 gutter 中央，箭头羽尾朝右、箭尖朝左
> 所有箭头要明显比共边角色的躯干更靠后 (画在角色背景层)，避免遮挡跨 gutter 的人物身体。
> 箭头颜色统一用同一种暖橙色，让读者一扫即知 "这是阅读路径"，与红色 LEASE 绳区分开。
>
> 出场角色（每一格里都画得一致、可辨认）：
> - VAULT：戴圆框眼镜、围着围裙、袖套套到肘部的图书管理员；柜台后立着写有 "Library Set: break-glass-team" 的木牌
> - READER A：戴鸭舌帽、背双肩包的工程师，"借用人 A"
> - READER B：扎马尾、抱平板电脑的工程师，"下一位借用人"
> - READER C：戴毛线帽的小个子工程师 (仅作背景排队人员)
> - BOOK：三本一模一样的硬皮书，书脊贴标 svc-ops-1 / svc-ops-2 / svc-ops-3，封面上有钥匙孔
> - KEY：金色锻造钥匙，每次新打造的钥匙齿形不同 (用以区分 "旧密码 vs 新密码")
>
> 5 格内容：
>
> 第 1 格 [READER A ─── VAULT] —— 申领请求
>   READER A 在左，VAULT 在右。A 递出一张写着 "check-out" 的小卡片给 VAULT。
>   VAULT 身后货架上立着三本书 svc-ops-1/2/3，全部贴着绿色 "AVAILABLE" 小标签。
>   VAULT 站在 1↔2 共边线上，身体一半在格 1 右、一半在格 2 左。
>
> 第 2 格 [VAULT ─── READER A] —— 现场打造钥匙 #1 + 系上 Lease
>   VAULT 在左 (与第 1 格共享)，READER A 在右。VAULT 站在小铁砧前刚锻好一把齿形为 "锯齿型" 的金钥匙 KEY#1，
>   把 svc-ops-1 + KEY#1 一并递给 A。A 的手腕上系一根红色绳子 (标签 "LEASE")，
>   绳子另一头绑在柜台旁的老式沙漏 (标签 "TTL") 上。沙漏正在缓缓漏沙。
>   柜台木牌新挂出 "svc-ops-1 = CHECKED OUT" 红字小卡。
>   READER A 站在 2↔3 共边线上。
>
> 第 3 格 [READER A ─── READER B] —— 借出期间排他独占
>   READER A 在左 (与第 2 格共享)，READER B 在右，READER C 在 B 身后做背景。
>   A 抱着 svc-ops-1 + KEY#1 向画面外走，A 手腕上的红绳仍延伸回左侧 (暗示 Lease 还连着 Vault)。
>   B 伸手想从远处货架上取 svc-ops-1，但货架上 svc-ops-1 的位置只剩一个空缺 + 红色 "TAKEN" 牌；
>   B 只能干瞪眼看着，C 在后面叹气。剩下的 svc-ops-2/3 仍贴 "AVAILABLE"。
>   READER A 整个身体跨 3↔4 共边线 (3 在上、4 在下)——3 格里画 A 的上半身，4 格里画 A 的下半身/转身回头。
>
> 第 4 格 [READER A ─── VAULT] —— 归还，旧钥匙作废
>   位于下排右侧。READER A 在右 (与第 3 格上方共享)，VAULT 在左。
>   A 把 svc-ops-1 + KEY#1 放回柜台。手腕上的红绳 "啪" 地断开 (画一道闪电+断绳特效)，沙漏被拿下。
>   VAULT 把 KEY#1 丢进旁边一个标 "INVALIDATED" 的小铁桶，桶上盖着 "OLD PASSWORD" 戳印。
>   VAULT 站在 4↔5 共边线上 (横向)，身体一半在格 4 左、一半在格 5 右。
>
> 第 5 格 [VAULT ─── READER B] —— 现场打造钥匙 #2 给下一位
>   位于下排左侧 (画面最左)。VAULT 在右 (与第 4 格共享)，READER B 在左。
>   VAULT 在同一个铁砧上刚锻好另一把齿形完全不同 (例如 "波浪型") 的金钥匙 KEY#2，
>   把 svc-ops-1 + KEY#2 递给 B。B 的手腕上被系上一根新的红色 LEASE 绳，绑到一只重新翻转开始计时的新沙漏上。
>   柜台木牌上原来的 "svc-ops-1 = CHECKED OUT" 红卡换成了新的 "CHECKED OUT (B)" 卡。
>   背景虚线小框里画 KEY#1 和 KEY#2 并排对比，KEY#1 上盖一个红色 "X" 戳——强调
>   "同一本书，每次借出都是一把全新钥匙"。
>
> 关键英文短词写在画面元素上 (不出现中文)：
>   "check-out" (格1 卡片) / "LEASE" (格2/格5 红绳标签) / "TTL" (格2/格5 沙漏)
>   "AVAILABLE" / "TAKEN" (货架标签) / "CHECKED OUT" (柜台木牌)
>   "INVALIDATED" / "OLD PASSWORD" (格4 铁桶) / "NEW PASSWORD" (格5 KEY#2 上方小气泡)
>   顶部横幅大字标题 "Library Set: break-glass-team"
>
> 整体气氛活泼幽默；每一格里 "共边角色" 务必画成同一个姿势/服装/颜色，
> 让读者扫一眼就读懂 "A→Vault→A→B (排队失败) →A→Vault→B" 这个借出—独占—归还—换钥匙的接力。
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

借出（check-out）动作的不变量：

1. **挑一个 `available=true` 的账号**，标记为 `available=false`
2. **把该账号当前的密码**（也就是上一次 check-in 时新轮转出来的那串）作为 Lease 的 `data` 返回给借用人
3. 与借用人的 Vault Token / Entity 绑定——**只有同一个 Token / Entity 能 check-in**（`disable_check_in_enforcement=false` 时）
4. 起 Lease 计时（受 set 上的 `ttl` / `max_ttl` 约束）

归还（check-in 或 Lease 到期）的不变量（这是官方明确写明的核心动作）：

1. **轮转该账号的 LDAP 密码**为一个全新的随机字符串——借用人手里那份密码立刻失效
2. 标记为 `available=true`
3. 等待下一个借用人

> Library 与 Static Role 的差异：Static 是"一个账号长期一个密码、定时轮转"；Library 是
> "一个账号被一个人**短期独占**，每次易主都换密码"。前者关心"过去是否泄露"，后者关心"借出期间是否唯一"。

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

1. **AD 改密必须走 LDAPS** —— Active Directory 服务端规则：`unicodePwd` 只接受加密通道上的修改。
   `ldap://` 上的"我改密总是失败" 99% 是这个问题。这与 Vault 无关，是 AD 端的硬约束。

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
