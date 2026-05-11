---
order: 92
title: 9.2 加密即服务（EaaS）：让一个 Go Web 应用『不再保管密钥』
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.2 加密即服务（EaaS）：让一个 Go Web 应用『不再保管密钥』

> **核心结论**：**加密即服务（Encryption as a Service, 简称 EaaS）** 是 Vault transit 引擎背后的工程范式——它把『加密 / 解密这件事』从应用代码中**整体抽离**给 Vault：**应用持密文 / Vault 持钥匙**，应用代码里既没有任何密钥变量、也没有任何密码学库的调用，只有一句『把这串明文交给 Vault 加密』和一句『把这串密文交给 Vault 解密』。本节先把 EaaS 这套思想在责任边界上讲清楚，再用一份最小可运行的 Go + [Gin](https://github.com/gin-gonic/gin) Web 应用把它落到代码层面，让学员在终端里**亲眼看到** 业务数据库里只有 `vault:v1:...` 形式的密文、看到密钥轮转后旧密文如何无中断升级、看到吊销应用 Token 如何在毫秒级内切断整条业务读链路。

参考：
- 思想渊源（本节在此基础上重新组织与扩充）：[Encryption as a service: transit secrets engine — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/encryption-as-a-service/eaas-transit)
- 对照参考的 Java 实现（本节的 Gin 应用与之在外部行为上对齐）：[Encryption as a service: Spring demo — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/encryption-as-a-service/eaas-spring-demo)、[hashicorp-education/learn-vault-spring-cloud (GitHub)](https://github.com/hashicorp-education/learn-vault-spring-cloud)
- 已学衔接：[3.13 Transit 机密引擎](/ch3-transit)（密钥版本化、`rotate` / `rewrap`、`min_decryption_version`、信封加密等机制）、[2.6 Policies](/ch2-policies)（最小权限策略）、[5.6 Vault Proxy](/ch5-vault-proxy)（应用接入层缓存）、[7.3 Vault Proxy 在 K8s 中的部署](/ch7-vault-proxy)

---

## 1. EaaS 范式：三件事的责任边界

本节要谈的不是『一个新功能怎么用』，而是一个**架构选择**——它把传统应用里『谁来加密』『谁来保管密钥』『谁来轮转密钥』『谁来撤销访问』四件事的责任边界**重新划分**。

### 1.1 传统做法的三个老大难

绝大多数应用至今仍把『加密敏感字段』当作业务代码的一部分来写：

1. **谁加密**：业务代码里直接 `import` 一个密码学库（Java 的 `javax.crypto`、Go 的 `crypto/aes`），亲手 new 一个 cipher、亲手生成 nonce / IV、亲手把密文与 IV 拼起来落盘；
2. **谁保管密钥**：开发人员从环境变量 / 配置中心 / KMS 取出一段 key material，把它**长期常驻在应用进程的内存里**；
3. **谁轮转 / 撤销**：『轮转密钥』是一项极其罕见的、需要全员加班的运维事件，因为代码里硬编码了『当前用的是哪一把 key』，旧密文的解密路径与新密文的加密路径必须在某个上线窗口里小心翼翼地对齐。

这套做法的根本问题是：**密码学的复杂性、合规性、轮转 / 撤销的运维负担，被强行摊到了每一个业务应用上**。任何一个应用写错了 nonce 处理、忘了在某次轮转时升级旧密文、或是被攻陷之后 dump 了内存——一整批生产数据就会立即面临可被解密的风险。

### 1.2 EaaS 的责任重划

**Encryption as a service** 把上述三件事整体上移到 Vault 的 `transit/` 引擎，业务应用只剩下一个职责：『**当我要把敏感字段写进数据库前，调一次 `transit/encrypt`；当我要把它读出来用之前，调一次 `transit/decrypt`**』。具体地：

- **谁加密**：Vault 的 `transit/encrypt/<key>` 接口；业务应用从此**不需要 `import` 任何密码学库**，也不需要管 nonce / IV / 算法 / 密钥长度；
- **谁保管密钥**：Vault 的存储后端（对应用完全透明）；业务应用进程的内存里**只有 Vault Token**，**没有任何密钥材料**；
- **谁轮转 / 撤销**：Vault 自带『密钥版本化』——`rotate` 在密钥下追加一个新版本而非替换旧版本，旧密文用 `vault:v1:...` 这个前缀『自报家门』、Vault 自动按版本号选私钥；要把旧密文升级到新版本，用 `transit/rewrap` 在 Vault 内部一次完成『解密 + 重新加密』，**应用与运维都看不到明文**；要让旧版本彻底失效，用 `min_decryption_version` 一刀关旧版。

这就是 9.2 节『**应用持密文 / Vault 持钥匙**』这句口号的全部含义——它不是个修辞，它对应的是上述三件事的责任真实地、整体地搬到 Vault 这一侧。3.13 节已经把 `transit/` 引擎里这套机制讲透了，本节聚焦的不是『怎么用 transit 引擎』，而是『怎么用这套思路改造一个真实的 Web 应用』。

### 1.3 EaaS 与『把机密存进 Vault』的对照

学员在 [3.13 节](/ch3-transit) 已经看过 KV 与 Transit 互为镜像的对照表，本节再用一句话归纳，避免初学者把两件事混淆：

- **KV 引擎（3.2 / 3.4）**：业务数据库里**根本没有这个字段**，因为它整段被存进了 Vault；应用每次需要它就向 Vault 借一次明文。
- **Transit 引擎（本节，配 EaaS 范式）**：业务数据库里**完整地存着这个字段**，但它是密文；应用每次需要它就向 Vault 借一次解密能力。

> 选择哪一种，取决于这个字段是『一段属于 Vault 的全局机密』还是『一段属于业务实体（每个用户一份）的敏感字段』。前者用 KV，后者用 Transit + EaaS。

---

## 2. 为什么选『支付记录 + 信用卡号』作为范例

为了让本节的动手实验有一个具体、可参证、并且可以与社区现有代码互相印证的业务场景，本节选用与 HashiCorp 官方 [`vault-transit/`](https://github.com/hashicorp-education/learn-vault-spring-cloud/tree/main/vault-transit) 示例一致的『支付记录 + 信用卡号』这组业务语义。信用卡号是 PCI DSS 合规要求加密存储的高敏感字段，是 EaaS 模式最典型的目标场景之一。

本节动手实验中的 Go 应用在所有**外部可观察行为**上与上述 Java 示例严格一致，以便学员随时可以参照同一个 Java 实现看哪一步其实被『拆到框架背后』了：

- `POST /payments` —— 接收一笔支付记录的 JSON，里面带有 `name` 与 **`cc_info`（信用卡号）** 等字段；
- `GET /payments` —— 把所有支付记录取出来，`cc_info` 还原成明文一并返回；
- 后台数据库是 PostgreSQL；支付表里 `cc_info` 字段被声明为 `String`，**实际存的是密文**。

不论语言、框架、数据库怎么选，EaaS 闭环本身只有三步：

1. 写入路径：在记录被持久化到数据库**之前**，把 `cc_info` 字段送给 `POST /v1/transit/encrypt/<key>`，把返回的 `vault:v1:...` 字符串覆盖原字段，再交给 ORM / SQL 落盘；
2. 读取路径：从数据库取出记录**之后**，把 `cc_info` 字段（此时仍是 `vault:vN:...`）送给 `POST /v1/transit/decrypt/<key>`，把返回的 base64 明文还原后覆盖原字段，再交给 Web 层序列化为 JSON 返回；
3. 与 Vault 通信使用 `X-Vault-Token` HTTP 头携带 Token；密钥名是事先在 Vault 里 `vault write -f transit/keys/<key>` 创建好的。

这就是 EaaS 架构在代码层面的全部细节——其余的 Spring Boot / Spring Cloud Vault / PostgreSQL / Maven（或 Go 侧的 net/http / database/sql / Gin）都是为了把这三步『包装成一个能跑起来的应用』所必须的样板代码。**EaaS 闭环本身只有三步，与具体语言、具体 Web 框架、具体数据库无关**。

---

## 3. 本节的 Go + Gin 实现

本节配套的动手实验把上述三步在 Go + [Gin](https://github.com/gin-gonic/gin) 框架下实现。Gin 是 Go 生态最常用的 HTTP 路由框架，本节选择它的理由只有一个：它的写法直观、不掩盖底层 HTTP 细节，便于学员从源码中看清『请求进来后到底发生了什么』。

为了让本节与官方 Java 示例互相参证，本节的 Go 实现在所有**外部可观察行为**上严格对齐：

- **端点路径与字段名完全相同**——`POST /payments` 接收 `{"name":"...","cc_info":"..."}`、`GET /payments` 列出全部记录；`POST /payments` 的返回值同样是『包含刚插入这一条的数组』，且数组里的 `cc_info` 字段返回的是『刚刚落库的密文』本身（与 Java 示例一致，本节保持这一行为以便课堂上直观看到密文长什么样）；
- **数据库与表结构完全相同**——PostgreSQL 16，表 `payments(id VARCHAR(255) PK, name VARCHAR(255), cc_info VARCHAR(255), created_at TIMESTAMP)`，与官方 [`schema.sql`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/resources/schema.sql) 一一对应；连接口令 `postgres-admin-password`、库名 `payments` 也沿用官方 [`docker-compose.yaml`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/docker-compose.yaml) 的取值；
- **Vault 密钥名也完全相同**——`transit/keys/payments`，与官方 docker-compose 中 `vault-configure` 容器初始化的密钥一致。

与官方 Java 示例相比有两点刻意为之的实现差异：

- **不引入任何 Vault SDK**。Java 示例通过 `VaultTemplate.opsForTransit(path).encrypt(key, ccInfo)` 这种 Spring Cloud Vault 封装来调 Vault；本节的 Go 实现直接用标准库 `net/http` 调 Vault 的 REST 接口，`X-Vault-Token` 头由代码显式贴上去。这样学员看到的是 Vault HTTP API 本身的样子，而不是某个 SDK 的封装。
- **多了一个运维端点 `POST /admin/rewrap`**——官方 Java 示例没有这个端点，本节为了在实验第 2 步中让学员能在终端里直接观察『密钥轮转后用 `rewrap` 升级存量密文』的现象而增加。它的实现就是遍历表、对每条 `cc_info` 调一次 `transit/rewrap/payments`、把返回的新密文 `UPDATE` 回数据库。

应用对外暴露三个 HTTP 接口：

| 方法与路径 | 业务语义 | 对应的 Vault 调用 |
| --- | --- | --- |
| `POST /payments` | 新建一笔支付记录（带敏感字段 `cc_info`） | `POST /v1/transit/encrypt/payments` |
| `GET /payments` | 列出所有支付记录，`cc_info` 还原成明文返回 | 对每条记录调用 `POST /v1/transit/decrypt/payments` |
| `POST /admin/rewrap` | 运维端点：把所有旧密文升级到当前最新版本 | 对每条记录调用 `POST /v1/transit/rewrap/payments` |

> 应用源码不到 280 行，已经准备在实验环境的 `/root/eaas-app/app.go`，第 1 步会请学员打开浏览。请重点理解三件事：
> 1. 应用内**不存任何业务密钥**——它的进程内存里有的只是 Vault Token；
> 2. 写入路径上明文 `cc_info` **从不落库**，落库的只是密文；
> 3. 读取路径上每一次调用都向 Vault 借一次解密能力，应用本身不缓存明文。

---

## 4. 这套架构能扛住的与扛不住的

为了避免初学者在本节学完之后产生『从此万事大吉』的错觉，必须在动手之前明确这套架构的边界：

**它能解决的**：
- **数据库被脱库**：攻击者拿到完整数据文件，但密文对他毫无意义——他没有 Vault 也没有合法 Token；
- **密钥轮转的运维负担**：旧密文不需要『立刻全部升级』也能继续用；要升级就调一次 `rewrap`，业务零感知；要让旧版彻底失效就调高 `min_decryption_version`，一行命令；
- **应用代码里的密码学错误**：因为应用根本不写密码学代码——nonce、IV、模式、密钥长度全都由 Vault 负责。

**它不能解决的**：
- **应用被攻陷且 Token 没被吊销**：攻击者控制了应用进程，就拥有了应用 Token 的全部权限——他可以在 Token 失效之前持续调用 `transit/decrypt` 把库里所有密文一条条解出来。**这是 EaaS 的固有边界**；缓解手段是给 Token 配短 TTL、给 `transit/decrypt` 路径配速率限流（[9.1 节](/ch9-production-hardening)）、配置审计日志触发异常告警（[8.1 节](/ch8-audit-overview)）。
- **Vault 自身的可用性单点**：每次加 / 解密都需要联通 Vault；Vault 故障期间业务读链路立即不可用。生产中常用 [Vault Proxy](/ch5-vault-proxy)（5.6 节）做响应缓存与故障窗口降级，或者用[信封加密（DEK）](/ch3-transit) 把大对象的对称加密放在应用本地、只让 Vault 加解密那把短短的数据密钥。
- **明文在内存中短暂出现**：解密后的明文必然在应用进程内存里短暂存在；任何能拿到内存 dump 的攻击者仍可能在窗口内捞到明文。这是端到端密码学的固有限制，不是 EaaS 特有的弱点。

---

## 5. 本节小结

把上述内容并排放在一起即可形成一份『EaaS 上手最小检查清单』：

1. **范式上**——应用持密文 / Vault 持钥匙，三件事整体搬到 Vault：谁加密、谁保管密钥、谁轮转 / 撤销；
2. **接口上**——业务代码只写 `encrypt(明文) → 密文落盘` 与 `decrypt(密文) → 明文使用` 两条直线，不接触任何密码学原语；
3. **运维上**——`rotate` 增版本、`rewrap` 升级存量、`min_decryption_version` 一刀关旧版、吊销 Token 一刀切断业务读链路；
4. **策略上**——给应用一个最小权限 Token（仅允许对那一把密钥做 `update`），并配合短 TTL；
5. **兜底上**——叠加速率限流、审计日志、Vault Proxy 缓存；理解 EaaS 不能解决『应用被攻陷且 Token 没被吊销』这一固有边界。

掌握这份清单后，可在动手实验中亲自把一个 Gin 应用接上 Vault transit 引擎，依次复现『落盘只有密文』『密钥轮转无中断』『Token 吊销切断业务』三个关键现象。

---

## 6. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 主机上启动 dev 模式的 Vault 与一份预先准备好的 Gin 应用，依次完成『启用 transit、运行应用、`cat` 数据文件验证只有密文 → `rotate` 增版本、`rewrap` 升级存量 → 用最小权限策略发应用专用 Token、吊销后观察业务被切断』三段操作。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-eaas-transit" title="实验：用 Gin Web 应用演示 Transit 加密即服务（EaaS）" />
