---
order: 94
title: 9.4 端到端案例：用 Vault 接管 OpenLDAP 用户口令的轮转生命周期
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.4 端到端案例：用 Vault 接管 OpenLDAP 用户口令的轮转生命周期

> **核心结论**：本节把 [3.10 节](/ch3-ldap) 中讲过的 LDAP 机密引擎放到一个**完整的、可复现的端到端剧本**里：先在一台主机上启动一台干净的 OpenLDAP 服务器，其中预置一位真实的目录用户 `alice`，她的口令最初由人工管理；然后启用 Vault 的 `ldap/` 引擎，把『轮转 alice 的口令』这件事整段交给 Vault；最后**亲眼看到** —— 用 Vault 当下发出来的口令绑定 LDAP 成功、用之前那一份口令立即失败、再触发一次轮转后**前一份**口令也立即失败。整套流程不引入任何商业组件、不依赖任何云资源，只用开源版 Vault 与开源 OpenLDAP。

参考：
- 思想渊源（本节在此基础上重新组织、补足初学者需要的概念铺垫并把『把口令交给一个最小应用使用』这一段补完）：[Manage LDAP credentials with Vault — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/secrets-management/openldap)
- 已学衔接：[3.10 LDAP 机密引擎](/ch3-ldap)（Static Role / Dynamic Role / Library Set 三种模式的机理与配置字段）、[2.3 Lease](/ch2-lease)（Static Role 的口令为何**没有**租约）、[2.6 Policies](/ch2-policies)（本节末尾给出最小化的 admin / consumer 两条策略）

---

## 1. 学习这一节之前，先把名词理顺

本节面向**没有 LDAP 实战经验**的学员。如果你已经熟悉这几个名词，可以直接跳到第 2 节。

- **LDAP（Lightweight Directory Access Protocol）**：一种『读多写少』的目录服务协议，把组织里的人、组、设备等对象按一棵树存起来。最常见的开源实现就是 [OpenLDAP](https://openldap.org/)。
- **目录树（DIT）与 DN**：每一个对象都对应树上的一个节点，节点的全路径叫 **Distinguished Name（DN）**，从叶子到根用逗号分隔，例如 `cn=alice,ou=users,dc=learn,dc=example` —— 它表示『在 `dc=learn,dc=example` 这棵树里、`ou=users` 这一支下、`cn=alice` 这个对象』。
- **`cn` / `ou` / `dc` 这三个前缀是什么**：它们都是 LDAP 标准里用来给节点命名的**属性名**，每一段 `属性=值` 在 DN 里叫一个 **RDN（Relative Distinguished Name，相对名）**，多个 RDN 用逗号拼起来就构成一条完整 DN。最常见的三种：
  - **`dc`（domain component，域名分量）**：把一个 DNS 域名按点切开，每一段写成一个 `dc=`。例如 `learn.example` 这个域写成两段 `dc=learn,dc=example`，连起来就是这棵目录树的**根**。它只是一个『按 DNS 习惯给目录树取名』的约定，与真实 DNS 解析没有任何关系。
  - **`ou`（organizational unit，组织单元）**：树里的一级『分组目录』，相当于文件系统里的『文件夹』。本节用 `ou=users` 装真实用户、`ou=groups` 装组对象——纯粹为了把不同种类的对象分开放，方便日后写 ACL 与搜索范围。
  - **`cn`（common name，常用名）**：叶子节点上『这个对象叫什么』的标识，相当于文件系统里的『文件名』。本节里 `cn=alice` 就是用户 alice 自己；`cn=admin` 就是 LDAP 管理员账号。
  - 把这三段拼起来读 `cn=alice,ou=users,dc=learn,dc=example` 就是『在 learn.example 这棵树的 users 文件夹里，叫 alice 的那个对象』。
- **`bind` 与口令**：客户端连上 LDAP 之后必须**绑定（bind）** 一个 DN 才能后续发请求。最常用的『simple bind』就是『DN + 口令』这一对凭据。绑定成功 ≈ 登录成功。
- **`binddn` / `bindpass`（在 Vault 这一侧的术语）**：Vault 用来连 LDAP 的那一对凭据。它必须有权限去**修改**目标用户的 `userPassword`。本节里我们**专门为 Vault 建一个最小权限的服务账号** `cn=vault,ou=services,dc=learn,dc=example`，初始口令 `2VaultBootstrap`，olcAccess 只授予它『写 `userPassword`』这一件事——**不**用 LDAP 的 rootdn `cn=admin`。理由见第 4 节。
- **Static Role**：[3.10 §3](/ch3-ldap) 已经详细解释过——『LDAP 里**已经存在**这个账号、Vault 只负责按周期把它的口令轮成新随机串』。本节全程使用这一种模式。
- **Static Role 不签发 Lease**：与 [2.3 节](/ch2-lease) 介绍的 AWS / Database 等动态凭据不同，Vault 读到的 LDAP 口令**不会自己过期**——只会在下一次轮转时**被覆盖**。应用如果一直不重新读，它手里那一份就一直能用，直到下一次轮转把它在 LDAP 这一端作废。

> **如果你完全没接触过 LDAP**，也不必为以上每一条细节焦虑。本节末尾的动手实验里，每一条 `ldapsearch` 命令都会在正文里逐个参数解释清楚，看完一遍命令的输出，回头再看这一段术语会自然贯通。

---

## 2. 本节要讲的剧本：从『人工管口令』到『Vault 管口令』

为了让本节贴近真实工程，剧本只设两个角色，与官方 [OpenLDAP 教程](https://developer.hashicorp.com/vault/tutorials/secrets-management/openldap) 保持一致：

- **admin**（Vault 管理员）：本节里就是你自己，持有 Vault 的 root token；负责启用 `ldap/` 引擎、写连接配置、把 Vault 服务账号自身的 bindpass 也轮一遍、为 alice 创建一条 Static Role；
- **alice**（最终消费方）：目录里已经存在的一位真实用户；本节里我们不真的『扮演』她去登录什么图形界面，而是用 `ldapsearch` 的 simple bind 模拟『某一个外部应用拿到口令后向 LDAP 验证身份』这个动作。

剧本五幕：

| 幕 | 谁在做 | 动作 | 验证方式 |
| --- | --- | --- | --- |
| ① 启动 LDAP | admin | 启动一台 OpenLDAP 容器，预先创建用户 `alice` 并写入初始口令 `1LearnedVault` | `ldapsearch -D cn=alice... -w 1LearnedVault` 成功 |
| ② 启用 + 配置引擎 | admin | `vault secrets enable ldap` + `vault write ldap/config ...` | `vault read ldap/config` 看到 url / binddn |
| ③ 轮转 root 凭据 | admin | `vault write -f ldap/rotate-root` —— 让 Vault 自己持有一份**没人见过**的服务账号口令 | 再用旧 `2VaultBootstrap` 去 bind `cn=vault` 立即失败 |
| ④ 创建 Static Role | admin | 把 alice 这条 DN 注册到 `ldap/static-role/learn`，定为 24 小时一轮 | `vault read ldap/static-cred/learn` 拿到一份新随机口令；用旧 `1LearnedVault` bind 立即失败 |
| ⑤ 应用消费 | alice 的『应用』 | 一段最小的 bash 脚本：每次启动都向 Vault 取最新口令，再用它 bind LDAP；中途手动触发一次 `vault write -f ldap/rotate-role/learn`，演示同一段脚本第二次执行时无缝取得新口令 | 两次脚本执行**输出的口令字符串不同**，但**两次都 bind 成功** |

剧本结束时，`alice` 这个账号的口令**只有 Vault 知道**——它是一段你从未见过、应用代码里也没有出现过的随机字符串；任何人想用 alice 的身份做事，都只能通过 Vault 去取那一刻的口令；想让所有人手里的口令立即作废，只需要再调一次 `rotate-role`。

---

## 3. Static Role 在这一幕里到底干了什么

[3.10 §3](/ch3-ldap) 已经把 Static Role 的字段一一列过。本节强调三个**初学者最容易踩坑的细节**：

1. **创建 Static Role 的那一瞬间，alice 在 LDAP 里的现有口令会被立刻覆盖掉**。这就是为什么剧本第 ④ 幕之后，旧口令 `1LearnedVault` 会立即失效——这不是某种延迟生效，而是 `vault write ldap/static-role/learn` 这一条命令本身就会触发一次『首次轮转』。如果你的真实业务还没改造成『每次启动都从 Vault 读口令』，请务必加上 `skip_import_rotation=true`（[3.10 §3 注意 4](/ch3-ldap) 已详细解释），否则下一次应用启动会被 LDAP 拒之门外。
2. **`vault read ldap/static-cred/learn` 是『读』而不是『签发』，所以它不消耗任何 Lease，可以反复读、读出来都是同一个值**。这一份值要等下一次轮转——无论是定时到点还是手动触发 `ldap/rotate-role/learn`——才会变。
3. **轮转后，前一次拿到的口令在 LDAP 这一端立即失效**。Vault 的内部状态里同时保留着 `password`（当前）与 `last_password`（上一次）两个字段，但 `last_password` 只是给『短暂的灰度窗口』用的——LDAP 服务器并不接受『last_password』，凡是没及时刷新过口令的应用都会立刻收到 `Invalid credentials`。

> 第 3 点是本节剧本第 ⑤ 幕的关键看点。它用最小的成本把『口令轮转』这件事的语义钉死：**应用只要愿意每次启动都向 Vault 取一次口令，就再也不需要为口令到期而停机；反过来，应用如果还在依赖『把口令写死在配置文件里』的老路子，即使接入了 Vault 也享受不到自动轮转的安全收益**。

---

## 4. 为什么要立刻 `rotate-root`，以及为什么 binddn 要用专用服务账号

### 4.1 binddn：用专用服务账号，不要用 LDAP rootdn

初学者最容易直接抄起 `cn=admin,dc=learn,dc=example`（OpenLDAP 容器里的那位『超级用户』）当 binddn——这在生产里是反模式，原因有两层：

- **权力过大违反最小权限原则**：`cn=admin` 是 mdb 后端的 *rootdn*，享有这个数据库上**绕开 ACL 的隐式全权**；Vault 只需要『改 `userPassword`』这一项能力，把 rootdn 交给它等于把整张目录的写权限都让出去。
- **`rotate-root` 在 rootdn 上根本轮不动**：slapd 对 rootdn 的 bind **只查 `cn=config` 里的 `olcRootPW`**，完全不看 DIT 里同名条目的 `userPassword`；而 Vault 的 `rotate-root` 是通过 `ldapmodify` 去改 DIT 里的 `userPassword`。结果就是 Vault 报 `Success!`，自己也能用新口令 bind，**但旧口令通过 rootdn 这条捷径永远有效**——rotate 形同虚设。

所以本节的剧本是：init 时建一个 `cn=vault,ou=services,dc=learn,dc=example` 的普通条目，给它一条精确到 `userPassword` 的 olcAccess 写权限；Vault 用它做 binddn；rootdn `cn=admin` 留作运维侧的 break-glass，**永远不交给任何自动化系统**。

### 4.2 rotate-root：写完 ldap/config 的下一条命令

在第 ③ 幕里我们刚一写完 `ldap/config` 就立刻调 `vault write -f ldap/rotate-root`。这一条命令做的事是：

1. Vault 用刚刚写进 `bindpass` 的那一份口令绑定 LDAP；
2. 在 LDAP 这一端把 `binddn`（也就是 `cn=vault`）**自己**的 `userPassword` 改成一段新随机串；
3. Vault 在内部存储里同步记下这份新口令；
4. **关键**：这份新口令**不能再被任何 API 读出来**——`vault read ldap/config` 也好、Vault 自己的存储后端也好，都不再以明文形式向外吐它。

这一步的意义有两层：

- **缩短『谁见过 binddn 口令』的清单**：在第 ② 幕，`2VaultBootstrap` 这串字符同时存在于（i）你的命令行历史、（ii）init 脚本、（iii）Vault 内部存储。第 ③ 幕之后，前两份依然存在但**已经不再有效**——LDAP 端 `cn=vault` 的 `userPassword` 被新随机串覆盖了。即使有人从 shell 历史或镜像里把 `2VaultBootstrap` 翻出来，他也再也不能拿这一份去操作 LDAP。
- **把 binddn 这把钥匙锁进 Vault**：从此 Vault 是这一对服务账号凭据的**唯一持有者**。任何想以 `cn=vault` 身份动 LDAP 的人，要么有 Vault 的 root token、要么有一个能动 `ldap/*` 的策略。这正是 Vault 把『谁能做什么』从『谁知道什么口令』转写成『谁有什么策略』的本意。

> **这一步不能在生产里『以后再补』**。如果业务已经上线之后才补做 `rotate-root`，那段时间里所有见过 `bindpass` 的人都依然能直接绕开 Vault 操作 LDAP。最佳实践是『写完 `ldap/config` 的下一条命令就是 `rotate-root`』。

---

## 5. 最小策略集：把 root token 换掉

剧本里我们使用 root token 执行了全部命令，是为了把注意力集中在『LDAP 引擎本身怎么用』。在生产里应当为两个角色各下发一条最小策略；本节给出可以直接 `vault policy write` 的两份样本：

```hcl
# admin-policy.hcl —— 给『管 LDAP 引擎』的那位运维
path "sys/mounts/ldap" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "ldap/config" {
  capabilities = ["create", "read", "update"]
}
path "ldap/rotate-root" {
  capabilities = ["update"]
}
path "ldap/static-role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "ldap/rotate-role/*" {
  capabilities = ["update"]
}
```

```hcl
# consumer-policy.hcl —— 给『拿 alice 的口令去用』的那个应用
path "ldap/static-cred/learn" {
  capabilities = ["read"]
}
```

两份策略的对照非常清晰：admin 持有『管引擎、改配置、定义谁可以被 Vault 接管、强制轮转』的全部能力，但**不能读任何具体口令**——读口令是消费方的职责；consumer 持有的能力则收窄到『只能读 learn 这一条 static-cred 的口令』，连同一目录下的 `ldap/static-cred/anything-else` 都读不到。

> 在课程动手实验里，为了让初学者把心思放在『流程长什么样』而不是策略调试上，我们仍然用 root token；但这两份策略是把这一节挪进生产的**最小**改动。

---

## 6. 动手实验导引

本节配套的交互式动手实验把第 2 节的五幕剧本拆成四步：

1. **Step 1**：启动 OpenLDAP 容器、预先创建用户 alice、用初始口令 `1LearnedVault` 验证『此时 alice 的口令是人工管理的』；
2. **Step 2**：启用并配置 `ldap/` 引擎（binddn 用专用服务账号 `cn=vault`，不是 rootdn）、立刻 `rotate-root`，验证旧的 `2VaultBootstrap` 已经在 LDAP 端失效；
3. **Step 3**：创建 `ldap/static-role/learn`、读 `ldap/static-cred/learn` 拿到 Vault 当下持有的口令，用它 bind 成功，再用旧的 `1LearnedVault` bind 失败；手动 `rotate-role` 一次，再次验证『前一份口令也失效了』；
4. **Step 4**：写一段最小 bash 脚本，模拟一个『每次启动都从 Vault 取口令』的应用——前后两次运行之间手动 `rotate-role`，看到脚本的两次输出口令不同但**都 bind 成功**。

> 实验全程在单台主机上完成；OpenLDAP 运行在 Docker 容器内、Vault 以 dev 模式作为宿主机进程运行；与 [3.10 节](/ch3-ldap) 的动手实验**复用同一套技术栈**，只是把 base DN 改成 `dc=learn,dc=example`、用户改成 alice，以便与官方教程一一对照。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-ldap-rotation" title="实验：用 Vault 接管 OpenLDAP 用户口令的轮转生命周期" />
