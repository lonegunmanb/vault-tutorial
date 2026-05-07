---
order: 69
title: 6.9 User Lockout：内核级防暴力破解机制
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.9 User Lockout：内核级防暴力破解机制

> **核心结论**：当某个用户在很短的时间内连续提供了若干次错误的登录凭据，Vault 会主动**暂停**为该用户继续校验凭据，并直接返回"权限被拒绝（permission denied）"。这套机制称为 **user lockout（用户锁定）**，由 Vault 内核统一实现，开箱即用，无需额外组件。本节按"概念与术语 → 默认行为 → `user_lockout` 配置块及四个参数 → 优先级链 → 三种禁用方式 → `/sys/locked-users` API"的顺序展开，并在末尾给出一个可在终端里直接复现锁定与解锁全过程的动手实验。

本节是第 6 章的最后一节。在 6.6 节"HA 模式"、6.7 节"服务注册"、6.8 节"遥测与 UI"分别处理完"集群可用性"与"可观测性"之后，本节回到"集群面对恶意输入时的内核级自防御能力"这一维度。

---

## 1. 概念与术语：四个名词必须先分清

User lockout 用四个名词描述一个状态机：**lockout threshold（锁定阈值）** 是触发锁定前允许的连续失败登录次数；**lockout duration（锁定持续时间）** 是用户被锁定后无法再尝试登录的时长；**lockout counter reset（锁定计数器重置时长）** 是在没有任何失败尝试的前提下，将累计失败计数清零所需的安静期；**disable_lockout（锁定禁用开关）** 是布尔型开关，置为 `true` 即关闭该机制。

锁定计数器在两类事件上被清零：一次成功登录、或在 `lockout_counter_reset` 指定的时长内没有发生任何失败尝试。这套机制可以同时挫败自动化暴力破解与针对性的口令猜测攻击。

> **必须明确给学员的一个安全提示**：user lockout 在请求处理流程中**很早**就被触发，因此可能向外部观察者**泄露**用户名是否真实存在的信息——攻击者可以根据"是否被锁定"这一现象去枚举有效用户名。这是该机制设计上的内在权衡，不是实现缺陷。

![user lockout 状态机：失败计数累积、达到阈值进入锁定窗口、duration 过后或 counter_reset 静默期后回到正常态](/images/ch6-user-lockout/lockout-state-machine.png)
> 绘图提示词：hand-drawn ink line drawing with soft watercolor wash, 一个真实的金属保险柜门示意图，门上有一个老式机械计数器（counter）逐步累积刻度，刻度走到红色 threshold 标记后保险柜门被一根铜锁链锁住（lockout），旁边有一个沙漏在倒计时表示 lockout duration，沙漏旁边还有一个独立的小沙漏表示 lockout counter reset 静默期；线条手绘风格，水彩淡色阴影，专业术语用英文标签，其他说明用中文标签

---

## 2. 默认行为：开箱即用的三组数值

User lockout 功能**默认启用**，三项核心参数的默认值分别为：lockout threshold = **5 次**、lockout duration = **15 分钟**、lockout counter reset = **15 分钟**。

只有三类认证方法支持 user lockout：**userpass、ldap、approle**。其它认证方法（例如 token、kubernetes、oidc/jwt 等）**不**走这条防御链路——这与它们的失败语义不同有关：例如 token 是单次明文比对、OIDC 的失败发生在外部 IdP，不在 Vault 内部。该特性自 **Vault 1.13** 起提供。

---

## 3. `user_lockout` 配置块：按 stanza 名称选择作用域

在配置文件里通过 `user_lockout` 顶层块声明锁定行为，块名（stanza name）即作用域。合法的块名只有四个：`all`、`userpass`、`ldap`、`approle`；其中 `all` 表示"对全部三种支持的认证方法生效"，其余三个分别只对对应方法生效。

```hcl
user_lockout [NAME] {
  [PARAMETERS...]
}
```

四个可用参数前文已介绍：`lockout_threshold`（字符串型，失败次数阈值）、`lockout_duration`（字符串型，锁定持续时长，例如 `"10m"`）、`lockout_counter_reset`（字符串型，计数器重置静默期）、`disable_lockout`（布尔型，禁用开关）。

官方示例如下，可直接拿来当解释样板：

```hcl
user_lockout "all" {
  lockout_duration       = "10m"
  lockout_counter_reset  = "10m"
}

user_lockout "userpass" {
  lockout_threshold = "25"
  lockout_duration  = "5m"
}

user_lockout "ldap" {
  disable_lockout = "true"
}
```

逐块解读这份示例：ldap 认证方法会因 `disable_lockout = "true"` 而**完全关闭**锁定行为；userpass 在合并后的最终参数为 threshold=25、duration=5m、counter_reset=10m（threshold 与 duration 显式覆盖了 `all`、counter_reset 沿用 `all`）；approle 由于没有写自己的块，会沿用 `all` 的 duration=10m 与 counter_reset=10m，并因为没有任何地方显式给出 threshold，最终采用默认值 5。

![三种 user_lockout 块（all / 具体方法 / 不写）合并产生最终参数的过程示意，强调"具体方法块覆盖 all 块、未指定的字段沿用上一层"](/images/ch6-user-lockout/stanza-merge.png)
> 绘图提示词：hand-drawn ink line drawing with soft watercolor wash, 三层叠放的真实纸质表格示意图：最底下是一张默认值表格（默认值标 "default"），中间是 user_lockout "all" 表格，最上层是 user_lockout "userpass" 表格；三张表格通过手绘箭头逐层覆盖，最终在右侧汇聚成一张"effective config"表格；线条手绘风格，水彩淡色阴影，参数名用英文（lockout_threshold / lockout_duration / lockout_counter_reset / disable_lockout），其余标注用中文

---

## 4. 优先级链：从挂载点 tune 一路回退到默认值

锁定**参数**（threshold / duration / counter_reset）的优先级从高到低如下：

1. 通过 `vault auth tune` 在某个具体挂载点（auth mount）上设置的值；
2. 配置文件里某个具体认证方法（userpass / ldap / approle）对应的 `user_lockout` 块；
3. 配置文件里的 `user_lockout "all"` 块；
4. Vault 编译进二进制的默认值。



锁定**禁用**比锁定参数还多一层最高优先级——**环境变量 `VAULT_DISABLE_USER_LOCKOUT`**。完整的禁用优先级链为：

1. 环境变量 `VAULT_DISABLE_USER_LOCKOUT`（一旦设置即在全局禁用，覆盖一切）；
2. `vault auth tune` 在挂载点上的设置；
3. 配置文件里某个具体认证方法的 `user_lockout` 块；
4. 配置文件里的 `user_lockout "all"` 块；
5. 默认值（即默认启用）。



这两条链合在一起的实操含义是：当线上发生疑似误锁定事件、需要紧急关掉这道防线时，**最直接的应急手段就是给 Vault 进程的环境里塞入 `VAULT_DISABLE_USER_LOCKOUT=true` 后重启**——它会无视所有配置文件与挂载点 tune 的存在。

---

## 5. `/sys/locked-users`：查询与解锁的两条 API

Vault 提供了一个专门的系统端点 `/sys/locked-users` 用于查询当前被锁定的用户、以及主动解锁某个用户。该端点自 Vault 1.13 起提供。

**查询：`GET /sys/locked-users`**——返回结构按命名空间分组（社区版只有 `root` 命名空间），每个命名空间下再按 `mount_accessor`（挂载点访问器，可在 `vault auth list -detailed` 输出中查到）分组列出被锁定的别名标识符（alias_identifier）。响应顶层 `total` 字段给出当前被锁定用户总数。可选参数 `mount_accessor`（作为 JSON 请求体传递） 用于把结果限制到某个具体挂载点。

```bash
curl -H "X-Vault-Token: ..." http://127.0.0.1:8200/v1/sys/locked-users
```

**解锁：`POST /sys/locked-users/:mount_accessor/unlock/:alias_identifier`**——通过路径参数指定挂载点访问器与被锁定的用户名/RoleID。两个路径参数都是必填项。`alias_identifier` 在 userpass 中对应用户名，在 approle 中对应 RoleID，在 ldap 中对应用户名。**该端点是幂等的**——即使目标用户当前并没有处于锁定状态，调用同样会成功返回，不会报错。

```bash
curl -X POST -H "X-Vault-Token: ..." \
  http://127.0.0.1:8200/v1/sys/locked-users/auth_userpass_xxxxxxxx/unlock/alice
```

> **挂载点访问器（mount accessor）的获取方法**：执行 `vault auth list -detailed`，输出表格中 `Accessor` 列即为对应认证方法挂载点的访问器，形如 `auth_userpass_79e2fe02`。

---

## 6. 小结

把本节涉及的配置面并排放在一起即可形成一份运维清单：

1. user lockout **默认启用**，默认 threshold=5、duration=15m、counter_reset=15m，仅对 userpass / ldap / approle 三种认证方法生效；
2. 通过 `user_lockout "<all|userpass|ldap|approle>"` 块按作用域配置参数，**具体方法块**覆盖 `all` 块；
3. 参数优先级：**挂载点 tune > 具体方法块 > all 块 > 默认值**；禁用优先级在最高位再插入一层 **`VAULT_DISABLE_USER_LOCKOUT` 环境变量**；
4. 通过 `GET /sys/locked-users` 查询、`POST /sys/locked-users/:accessor/unlock/:alias` 主动解锁，且解锁是幂等操作。

---

## 7. 动手实验

本节配套了一个 Killercoda 实验，学员将在单台 Killercoda 主机上启动一个开启了 userpass 的单节点 Vault，**亲手把 user_lockout 三个参数都调到很小的数值，故意触发锁定，再依次复现"列出锁定用户 → 主动解锁 → 用 `VAULT_DISABLE_USER_LOCKOUT` 全局关停"三段操作**，从终端直接观察本节正文中的几条结论。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-user-lockout" title="实验：触发并管理 Vault user lockout" />
