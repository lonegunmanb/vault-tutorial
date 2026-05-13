---
order: 94
title: 9.4 ACME 协议自动化 TLS 证书签发：让 Vault PKI 与 Caddy 自动协商并续期
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.4 ACME 协议自动化 TLS 证书签发：让 Vault PKI 与 Caddy 自动协商并续期

> **核心结论**：当一个组织内部的 TLS 证书数量从『几张』走到『几百张』时，沿用『手工生成 CSR、手工提交、手工下载、手工到期前续期』这套流程几乎必然会在某个早上以一次生产事故的方式收场。**ACME（Automatic Certificate Management Environment，自动证书管理环境）协议** 正是为了把这条流水线整体交给两个进程（一个 ACME 服务器、一个 ACME 客户端）按标准对话来跑而被设计出来的。本节先把 ACME 是什么、它解决了哪一类问题讲清楚，再把 Vault 1.14 起内置在 PKI 引擎里的 ACME 服务器能力与 [Caddy](https://caddyserver.com/) Web 服务器自带的 ACME 客户端拼到一起，让学员在终端里**亲眼看到** 一个『从未手工接触过任何证书』的 Web 服务器是怎么自动从 Vault 拿到一张可信证书并对外提供 HTTPS 服务的。

参考：
- 思想渊源（本节在此基础上重新组织，并补足初学者需要的概念铺垫）：[Manage certificates with ACME clients and the PKI secrets engine — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/pki/pki-acme-caddy)
- 协议规范：[RFC 8555 — Automatic Certificate Management Environment (ACME)](https://datatracker.ietf.org/doc/html/rfc8555)
- 已学衔接：[3.7 PKI 机密引擎](/ch3-pki)（根 CA / 中间 CA 的搭建、`role` 的概念、签发与吊销）、[6.2 监听器与 TLS 配置](/ch6-listener-tls)（生产环境如何给 Vault 自身配好 TLS）

---

## 1. 为什么需要 ACME：手工签发流程到底坏在哪

学员若已经完成 [3.7 节](/ch3-pki) 的实验，应当对『一次完整的内部 TLS 证书签发』经历过以下这套流程：

1. 在目标服务器上执行 `openssl genrsa` 生成一份**私钥**；
2. 用这份私钥生成一份**证书签名请求（CSR）**，里面填上业务域名、组织信息等；
3. 把 CSR 通过某个工单系统 / IM 截图 / `scp` 命令，**人肉送到** 持有 PKI 引擎写权限的运维同学那里；
4. 运维同学执行 `vault write pki_int/sign/<role> csr=@... ttl=...`，把签出来的 PEM 复制粘贴回去；
5. 业务方把证书放到正确的目录、改 Web 服务器配置、`reload`；
6. **三个月或一年后** —— 在某个没人记得的凌晨，证书悄无声息地过期，所有依赖它的下游服务集体 `tls: certificate has expired or is not yet valid`。

这套流程在『几张证书 + 一年期』的世代里勉强可用，但在『微服务 mTLS（每个服务一张证书，甚至每个 Pod 一张）』的现代架构里彻底失效。其根本症结只有两个字——**人肉**：

- 私钥从来没有离开过应当持有它的那台服务器，**这是好事**；
- 但围绕『证书诞生』与『证书续期』的所有动作都靠人来推动，**这是病灶**。一旦人忘了 / 病了 / 离职了 / 排班漏了，证书就过期。

ACME 协议要解决的就是把**第 3 ~ 5 步与第 6 步**整体自动化——让目标服务器自己生成 CSR、自己向 CA 申请、自己向 CA 证明『这个域名确实归我管』、自己拿到证书并装上、并在到期前自己重复整套流程。

---

## 2. ACME 协议在做什么：四个角色 + 三步对话

在跳到代码与命令之前，先建立一份『最小够用』的 ACME 心智模型。RFC 8555 描述的协议很厚，但课堂上只需要记住四个角色与三步对话。

### 2.1 四个角色

| 角色 | 在本节实验中扮演者 | 职责 |
| --- | --- | --- |
| **ACME 服务器（CA）** | Vault 的 `pki_int` 中间 CA | 接收申请、对申请方下达『所有权挑战』、验证通过后签发证书 |
| **ACME 客户端** | Caddy Web 服务器自带的 `caddy` ACME 客户端 | 生成私钥与 CSR、向 ACME 服务器申请、回应挑战、拿到证书并自动装载 |
| **要保护的域名** | 实验里那个虚拟的 `caddy.local` 主机名 | 客户端要为它申请证书 |
| **挑战路径** | 客户端在 `:80` 端口暴露的 `/.well-known/acme-challenge/<token>` | ACME 服务器借此确认『申请方真的控制了这个域名』 |

> **ACME 服务器与 CA 是什么关系？** ACME 是『一套与 CA 打交道的标准协议』，它本身不签发证书。所谓『ACME 服务器』指的是**一个把 ACME 协议作为前端、把背后某个 CA 的签发能力包装出来对外提供的服务端进程**——它与 CA 是『前台接待 + 后厨签发』的关系，通常打包在同一套软件里发布。例如公网上最有名的 [Let's Encrypt](https://letsencrypt.org/) 与 [ZeroSSL](https://zerossl.com/) 都同时扮演这两个角色：既是大家熟知的可信 CA，也对外暴露 ACME 协议端点。本节实验中，Vault 的 `pki_int` 中间 CA 也同时扮演这两个角色——CA 的身份由 `pki_int/` 这个 PKI 引擎挂载点提供，ACME 服务端的身份则由 `pki_int/acme/...` 这一组 HTTP 端点提供，二者背靠同一个 Vault 进程。

### 2.2 三步对话（HTTP-01 挑战为例）

```
ACME 客户端 (Caddy)                              ACME 服务器 (Vault PKI)
       │                                                  │
   (1) │ ── newAccount  / newOrder ──────────────────────► │
       │                                                  │
       │ ◄── "请把 token <X> 放到 /.well-known/acme-      │
       │       challenge/<X> 路径上让我能 GET 到"          │
       │                                                  │
   (2) │ <在本机 :80 把 <X> 文件准备好>                    │
       │                                                  │
       │     ◄────── HTTP GET /.well-known/acme-          │
       │              challenge/<X> ────── (Vault 主动回访) │
       │ ─────────────── 200 OK + token <X> ────────────► │
       │                                                  │
   (3) │ ── finalize（提交 CSR）────────────────────────► │
       │ ◄────────────── 颁发的 X.509 证书 ─────────────── │
```

三步对话的本质：
1. **下单**——客户端告诉 ACME 服务器『我想为域名 D 申请一张证书』；
2. **挑战**——服务器抛出『所有权挑战』（最常见的两种是 **HTTP-01** 与 **DNS-01**），让客户端证明自己确实控制 D；
3. **结单**——客户端通过挑战之后，把 CSR 提交给服务器，拿到正式证书。

> **HTTP-01 与 DNS-01 怎么挑选？** HTTP-01 要求 ACME 服务器能用 HTTP 访问到客户端所在的 80 端口，最适合『内网的 Web 服务器为自己申请证书』这个最常见场景，**也是本节实验采用的方式**；DNS-01 要求客户端能在权威 DNS 上添加一条 TXT 记录，最适合『为没有公开 80 端口的服务（比如内部数据库、API 网关后端）申请证书』，但需要 DNS 自动化能力。本节聚焦 HTTP-01，DNS-01 不在交互式实验的覆盖范围内。
>
> Vault 的开源版还支持另一种 **TLS-ALPN-01** 挑战，但它依赖 443 端口握手时的扩展协商，初学者难以直观观察、并且 Caddy 默认就走 HTTP-01，因此本节也不展开。

### 2.3 ACME 真正的红利不在于『一次签发』而在于『静默续期』

ACME 客户端拿到证书之后，会把证书的『签发时间 + 有效期』记下来；当寿命走过约 2/3 时，它会自动重复一遍上面的三步对话，无需人工介入。这个机制带来的真正变化是：内部证书的有效期可以**断崖式缩短**——从过去『为了减少人肉续期次数而被迫签 1 年』，缩到 24 小时甚至更短。短 TTL 的好处只有亲历过证书私钥泄露事件的运维才会真正体会：**泄露发生后能造成的伤害窗口，最多就是这张证书的剩余寿命**。

---

## 3. 为什么由 Vault 来扮演 ACME 服务器：与公网 CA 的边界

读到这里初学者很容易问出一个合理疑问：『公网上已经有 Let's Encrypt 这种成熟、免费、可信的 ACME 服务器了，为什么还要让 Vault 自己干这件事？』答案在于**信任域**：

- 公网 CA（Let's Encrypt 等）颁发的证书，其根 CA 已经被全球绝大多数操作系统与浏览器**预置信任**。这是公网 HTTPS 的基础设施。
- 但公网 CA 只为**你能向它证明所有权的公共域名**签证书。一台只能在公司内网（甚至只在 Kubernetes Service 网络内）被访问到的服务，公网 CA 是无能为力的——它没法用 HTTP-01 挑战回访这台服务。
- 内部 PKI 解决的恰恰是这一段：在公司**自建一个根 CA**，让所有公司设备/容器/Pod 都把这个根 CA 加入信任列表，然后用它来给内网服务签证书。**Vault 的 PKI 引擎正是用来管理这个内部 CA 的工具**。

把 ACME 协议植入 Vault PKI 引擎之后，公司内网的运维体验就变成了：

> 内部服务的开发者**不需要懂任何 PKI 知识**。他在自己的 Web 服务器（Caddy / Traefik / Nginx + cert-manager / 任何带 ACME 客户端的工具）配置文件里写一行『去这个 ACME directory 申请证书』、再写一行『证书要为这个域名申请』，剩下的全部自动化。

这就是 9.4 节『**把 ACME 这条公网早已成熟的自动化流水线引到内部 PKI 上**』的全部价值。

---

## 4. 为什么实验选 Caddy 当 ACME 客户端

[Caddy](https://caddyserver.com/) 是一款用 Go 编写的开源 Web 服务器，与 Nginx / Apache 同属一类、但有一项与本节主题强相关的设计差异——**自动 HTTPS 是它的默认行为**。在 Caddy 的配置文件 `Caddyfile` 里写下一个域名作为站点名，Caddy 启动后就会自动：

1. 用内置的 ACME 客户端去问『默认 ACME 服务器』要一张证书；
2. 在本机 `:80` 端口准备好 HTTP-01 挑战路径；
3. 拿到证书后立即在 `:443` 端口对外提供 HTTPS；
4. 在证书寿命过 2/3 时静默续期。

唯一需要为本节场景做的改动只有一行：**告诉 Caddy 别去找默认的 Let's Encrypt，去找我们这台 Vault 当 ACME 服务器**。这通过 Caddyfile 顶部全局块里的一行 `acme_ca <Vault ACME directory URL>` 完成。

> **能不能换成 Traefik / cert-manager？** 完全可以，原理一致——它们都是『带 ACME 客户端的下游软件』。本节选 Caddy 只因为它的『默认即自动 HTTPS』这一特性能让学员在最少的配置量下看清整条流水线；选了 Traefik 就不得不先讲一堆 entrypoint / router / resolver 概念，反而冲淡了 ACME 本身的故事。

---

## 5. 实验整体路线图

本节配套了一个 Killercoda 实验，三步走：

1. **Step 1**：先把 Caddy 以『纯 HTTP、不启用自动 HTTPS』的姿态跑起来——`curl http://caddy.local/` 能拿到 hello world，`curl https://caddy.local/` 失败。这一步是『反例』，建立一个清晰的对照基线。
2. **Step 2**：在 Vault 里搭一套两级 PKI（根 CA `pki` + 中间 CA `pki_int`），并在中间 CA 上**启用 ACME**。这一步会用到一份『一键脚本』，但脚本里每条命令都会在正文中逐句解释——重点是理解 `pki_int/config/cluster`、`pki_int/config/acme`、`secrets tune` 这三处对 ACME 不可或缺的配置。
3. **Step 3**：换一份指向 Vault ACME directory 的 Caddyfile 重启 Caddy，**什么手工证书操作都不做**，验证：
   - `curl --cacert <root.crt> https://caddy.local/` 拿到 hello world；
   - `openssl s_client` / `openssl x509` 看到证书的 Issuer 是 `learn.internal Intermediate Authority`；
   - 看 Caddy 的内部存储目录，确认它已经把私钥与证书自己保管好了，运维全程从未亲手碰过任何 PEM 文件。

---

## 6. 这套架构能扛住的与扛不住的

为了避免初学者在本节学完之后产生『把 Vault PKI 一开 ACME 就万事大吉』的错觉，必须明确这套架构的边界：

**它能解决的**：
- **内部证书数量 = 微服务数量** 这一规模下的运维负担——开发者无需懂 PKI 也能拿到证书；
- **证书静默过期** 导致的级联故障——续期是协议自动行为；
- **手工流程中的私钥泄露窗口**——CSR 不再被 IM 截图来传递，私钥从未离开过申请方主机。

**它不能解决的**：
- **域名所有权认证之外的授权问题**——HTTP-01 只证明『申请方控制了这个域名』，不解决『申请方应不应当为这个域名申请』。生产中需要配合 Vault 的 [PKI role](/ch3-pki) 中的 `allowed_domains` 与 ACME 的 EAB（External Account Binding）机制把『谁能为哪些域名申请』锁住。
- **ACME 客户端被攻陷**——攻击者控制了 Caddy 进程就能为它管的所有域名持续申请新证书。这与 [9.2 节](/ch9-eaas-transit) 里讨论的『应用被攻陷且 Token 没被吊销』属于同一类边界问题。
- **Vault 自身的可用性**——Vault 故障期间，已有证书继续可用（证书是离线工件），但**无法续期**；故障窗口若超过证书剩余寿命就会全面过期。生产部署需要按 [6 章](/ch6-config-overview) 所述把 Vault 集群本身做成高可用。

---

## 7. 本节小结

把上述内容并排放在一起，即可形成一份『把 ACME 引入内部 PKI 的最小检查清单』：

1. **协议上**——记住四个角色（ACME 服务器、ACME 客户端、域名、挑战路径）与三步对话（下单、挑战、结单）；
2. **服务器侧**——Vault 1.14+ 的 PKI 引擎自带 ACME 服务器，需要在中间 CA 上做三件事：配 `config/cluster` 的 `path` / `aia_path`、`secrets tune` 通过 ACME 必需的请求/响应头、`config/acme` 写 `enabled=true`；
3. **客户端侧**——Caddy 默认就是 ACME 客户端，把全局 `acme_ca` 改成指向 Vault 的 directory URL 即可；
4. **挑战方式**——交互式实验里走 HTTP-01；要做 DNS-01 需要叠加 DNS 自动化能力，超出本节范围；
5. **生命周期红利**——续期是协议自动行为，TTL 因此可以从『1 年』缩到『1 周/1 天』，泄露伤害窗口随之收窄；
6. **边界**——ACME 不解决申请方的合法性问题（用 PKI role 的 `allowed_domains` 与 ACME EAB 收口），不解决客户端被攻陷问题，不替代 Vault 集群自身的高可用建设。

掌握这份清单后，可在动手实验中亲自把一台 Caddy 接到 Vault PKI 的 ACME 服务上，依次复现『纯 HTTP 反例 → PKI + ACME 一次性配齐 → 全自动 HTTPS』三个阶段。

---

## 8. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 主机上启动 dev 模式的 Vault，先把 Caddy 以纯 HTTP 跑一遍作为对照，再启用并配置 PKI + ACME，最后让 Caddy 全自动从 Vault 拿到证书并对外提供 HTTPS。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-acme-caddy" title="实验：用 ACME 协议让 Caddy 从 Vault PKI 自动获取并续期 TLS 证书" />
