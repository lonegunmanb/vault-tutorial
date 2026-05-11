---
order: 91
title: 9.1 上线前的安全加固清单与请求速率限流配额
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.1 上线前的安全加固清单与请求速率限流配额

> **核心结论**：把一台"能跑起来"的 Vault 升级为"敢于面对真实生产流量的 Vault"，需要两层互相补充的工作——第一层是**安全加固清单**（production hardening），由一组贯穿操作系统、Vault 进程、网络边界与运维流程的硬性约束构成，目标是让"被攻破"这件事尽可能发生不了；第二层是**请求速率限流配额**（rate limit quota），它在「即便防线被绕过、即便上游应用出现行为异常」的兜底假设下，限制单位时间内进入 Vault 的请求数量，避免一台 Vault 集群被洪水流量直接拖垮。本节把这两层放在一起讲——前者来自官方 *Production hardening* 文档，后者来自官方 *Create a rate limit quota* 文档；本节末尾的动手实验会让学员在终端里**实际**配置一条速率配额、亲眼看到第 N+1 个请求被 Vault 拒收的过程。

参考：
- [Production hardening — Vault Docs](https://developer.hashicorp.com/vault/docs/concepts/production-hardening)
- [Create a rate limit quota — Vault Docs](https://developer.hashicorp.com/vault/docs/configuration/create-rate-limit-quota)
- 已学衔接：[6.2 Listener 与 TLS](/ch6-listener-tls)、[6.9 User Lockout](/ch6-user-lockout)、[8.1 审计日志综述](/ch8-audit-overview)

---

## 1. 为什么需要"上线前清单"这件事

一台开发机上的 Vault 与一台生产 Vault 的差距，不在于它们运行的是同一份二进制——而在于**它们身处的环境**：生产 Vault 必须假设「它的宿主机会被尝试入侵、它的网络会被尝试嗅探、它的进程会被尝试 dump 内存、它的存储后端会被尝试直接读盘、它的根令牌会被尝试盗用」。**Production hardening** 这份官方文档把上述假设拆解成一组可执行的最小约束，并按"**基线（baseline）**"与"**扩展（extended）**"两层组织：基线项是「绝大多数生产部署都应当满足」的硬性条件，扩展项是「带来更高安全性、但也带来更高运维成本，可按场景取舍」的进阶建议。

需要先给初学者澄清的两个术语：

- **威胁模型（threat model）**——指"我们究竟在防谁、防什么"。不同业务的威胁模型差异很大，但 Vault 的官方加固清单给出的都是**所有生产部署都共享**的基础威胁模型；
- **纵深防御（defense in depth）**——不假设任何单一防线绝对靠谱，而是叠加多层互不相同的防线，让攻击者每多走一步都要再付出一份成本。Vault 加固清单的所有条目都遵循这一思想。

---

## 2. 基线加固清单：分四个面向理解

官方基线条目数量较多，逐条死记意义不大；本节按"**进程身份与文件系统**、**网络与 TLS**、**操作系统级隔离**、**令牌与策略生命周期**"四个面向分组，每组挑出最关键的几条做必要的展开，方便初学者建立可迁移的心智模型。

### 2.1 进程身份与文件系统

第一条也是最重要的一条：**不要以 root 身份运行 Vault**。应当为 Vault 创建一个独立的、无特权的服务账号；该账号对 Vault 二进制本身、Vault 配置文件均**只有读权限**，可写范围只限定在「集成存储数据目录」与「`file` 类型审计设备的日志路径」这两类必要位置。

这条建议背后的逻辑是非常朴素的"最小权限"——一旦 Vault 进程被入侵，攻击者拿到的就只是这个服务账号的能力上限；如果 Vault 跑在 root 下，攻击者立刻就拥有整台机器；如果 Vault 进程哪怕有「能改写自己二进制或自己配置文件」的写权限，攻击者就能把恶意逻辑持久化进下次启动。

紧随其后的一条是**禁用 swap、禁用 core dump**：Vault 在内存里持有解封后的根密钥与各类敏感字段，一旦操作系统把内存页换到磁盘上的 swap 分区、或是因为崩溃把内存 dump 成 core 文件，攻击者只要有读盘权限就有机会拿到这些机密。Linux 上禁用 swap 的方法很多，禁用 core dump 的标准做法是把 `RLIMIT_CORE` 设为 0；如果用 systemd 管理 Vault 服务，就在 unit 文件里加 `LimitCORE=0`。

> **必须给初学者澄清的一点**：很多初学者第一反应是"把 swap 留着兜底总比 OOM 强"——对绝大多数业务进程确实如此，**但 Vault 是反例**，因为它的内存内容直接对应集群所有机密的安全。如果实在担心 OOM，正确的做法是把 Vault 单独跑在一台容量足够的机器上（见 2.3 节"单租户"原则），而不是给它留一个 swap 兜底。

### 2.2 网络与 TLS

**端到端 TLS** 是基线中最不可妥协的一条：所有与 Vault 进出的网络连接都必须 TLS 加密——包括客户端到 Vault、Vault 节点之间、以及 Vault 到外部存储后端。如果在 Vault 前面挂了反向代理或负载均衡器，必须确保从客户端经过代理一路到 Vault 的**每一段**都启用 TLS，而不是仅在客户端到代理这一段加密、再用明文连接代理与 Vault。

紧密相关的一条是**只用安全算法**：Vault 的 TLS listener 出于向后兼容考虑保留了一批历史算法，但若条件允许，应当切到 **TLS 1.3** 以确保使用现代加密原语并获得前向保密（forward secrecy）。

第三条是**网络流量必须被防火墙严格收敛**：用宿主机本地防火墙或云厂商的安全组功能，把允许进入 Vault 的源限制到必要的子网，并且把 Vault 自身向外发起的连接收敛到必要的目标（数据库、KMS、NTP 等）。

![进程身份／文件系统、网络／TLS、操作系统隔离、令牌生命周期四个加固面向像四道同心圆一样把 Vault 进程包在最里面](/images/ch9-production-hardening/four-rings-of-hardening.png)

### 2.3 操作系统级隔离

**单租户原则（single tenancy）**——Vault 应当独占其宿主机，不与其他业务进程共享操作系统，以减少"侧信道入侵"的可能性。同样的逻辑下，官方还建议**优先选择物理机而不是虚拟机、优先选择虚拟机而不是容器**：每多一层抽象就多一层潜在的逃逸面。

**限制对存储后端的访问**——即便 Vault 把所有数据加密落盘，攻击者只要能任意修改或删除存储里的键，就能造成数据损坏或丢失（哪怕看不到明文）。因此外部存储（无论是 Consul 还是云厂商对象存储）都要把访问权限收敛到只允许 Vault 节点本身。

**所有 Vault 节点的时间必须保持同步**——通过 NTP 或同等机制确保节点之间不发生时钟漂移；Vault 用本地时钟来执行 TTL 与 PKI 证书的生效/失效时间，时钟漂移会让主从切换时陷入难以排查的混乱。

### 2.4 令牌与策略生命周期

**避免使用根令牌（root token）**：Vault 初始化时打印的根令牌只应当用来完成最初一次性的引导工作（启用各种认证方法、加载初始策略等），完成后就应当吊销；后续若再需要根权限，可通过 `vault operator generate-root` 流程按需生成、用完再吊销。

**配置 user lockout**：开源版 Vault 默认对 approle / ldap / userpass 三种认证方法启用了用户锁定（详见 [6.9 节](/ch6-user-lockout)）；上线前应当复核默认阈值与持续时长是否与本组织的安全策略匹配。

**启用审计设备**：审计日志是事后取证与异常感知的唯一可靠依据（详见 [8.1 节](/ch8-audit-overview)）；Vault 默认**不启用任何**审计设备，必须在初始化完成后立刻挂载至少一台。

**短 TTL（短生命周期凭据）与最小权限策略**：Vault 颁发的令牌、X.509 证书等都应当尽可能设置较短的 TTL；策略也应当尽量简单、显式，少用通配符与模板。

**持续升级**：Vault 在不断修复安全问题与调整默认值（例如加密算法、密钥长度）。订阅 HashiCorp Announcement 邮件列表，按节奏跟进新版本。

**离职流程**：从外部身份提供商（IdP）里删掉一个账号，并不能立即吊销 Vault 中已经签发的令牌；下线一名员工时还要主动从 Vault 里把对应的实体（entity）从授权组里移除、把其活跃租约（lease）显式吊销。

---

## 3. 扩展加固清单：可按场景取舍的进阶项

扩展项不是"可有可无"，而是"带来更高安全性、但也带来更高运维成本"的条目；中小规模部署可先把基线项落地、再按业务敏感度逐步引入扩展项。

- **禁用 SSH / 远程桌面**：Vault 节点应当只通过 API 访问，**禁止**运维人员登入宿主机；调试信息全部通过集中式日志与遥测获取。
- **使用 systemd 安全开关**：官方 Vault Linux 包自带的 service unit 文件已经设置了 `ProtectSystem=full`、`PrivateTmp=yes`、`CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK`、`ProtectHome=read-only`、`PrivateDevices=yes`、`NoNewPrivileges=yes` 等一组开关，部署时不应当随意把这些开关关掉。
- **不可变升级（immutable upgrades）**：升级 Vault 版本时不要"原地"替换二进制，而是新拉一组带新版本的服务器、attach 到同一份共享存储、unseal 之后再下线旧节点；这样既减少了对宿主机的远程操作面，又便于回滚。
- **配置 SELinux / AppArmor**：在内核强制访问控制层面再叠加一层防线。
- **调整用户限制（ulimits）**：审视 Linux 上 `ulimit` 对最大文件数、连接数等的默认上限，避免上线后出现 "too many open files" 一类的错误。
- **理解 `disable_mlock` 与集成存储的内存权衡**：默认情况下 `mlock` 是开启的，能保证敏感数据不被换出到 swap，但同时把 OOM 风险放大；若选择关闭 `mlock`，就必须给 swap 文件本身加上加密。
- **集成存储用独立分区**：让集成存储数据目录使用独立分区，避免 Vault 把整块根盘写满之后影响到操作系统本身。
- **认证型反向代理作为兜底防线**：如果实在做不到频繁升级，可在 Vault 前架一台带认证的反向代理，给已知漏洞争取一段缓冲。

---

## 4. 把"洪水流量"挡在外面：请求速率限流配额

加固清单解决的是"被攻破"的问题；但即便所有防线都没有被突破，Vault 仍然会面临另一类常见的生产事故——**单个客户端、单个挂载点或单个命名空间产生的请求量超过 Vault 的处理能力**，把整个集群拖到不可用。这类事故的来源既可能是恶意（DoS 攻击、凭据填充），也可能是无心之失（一段写错的脚本以最大并发不停 retry）。

应对它的官方机制是**请求速率限流配额（rate limit quota）**——一种"在某个目标范围内限制每秒最大请求数"的规则。它属于 Vault **核心特性**，社区版与企业版都自带。

需要先给初学者明确一个**社区版的边界**：在社区版里，速率配额**只能按客户端的源 IP 地址（source IP）来分组**统计请求；按身份实体（entity）或更复杂的方式分组的能力属于企业版的扩展。

### 4.1 分组、阈值与"封禁窗口"：四个核心参数

创建一条速率限流配额走 `vault write sys/quotas/rate-limit/<NAME>` 命令，常用参数包括：

- `name`——配额规则名；
- `path`——目标范围。可以是命名空间、挂载点（如 `transit/`）、甚至挂载点下更深的路径（如 `transit/encrypt/orders`，即"limit `orders` 这把密钥的加密请求"）；以 `*` 结尾可表示前缀通配（如 `auth/token/create*`）。**`path` 留空即为整个集群的全局速率限流**；
- `rate`——浮点数。官方文档把它定义为「每秒允许的请求数（requests per second, RPS）」；当 `interval` 被显式拉长时（见下条），`rate` 即表示该窗口内的允许请求总数；
- `interval`——执行速率限制的窗口时长，默认为 1 秒；
- `block_interval`——一旦客户端触发速率上限，Vault 在 `block_interval` 这段时长内**完全拒绝**该客户端的任何请求；该参数默认为空字符串（行为上等价于不额外封禁，仅在当前窗口内拒收）。

> **粒度（granularity）的取舍**：把 `path` 设得越深、规则越精细，能够更准确地保护具体目标；但官方明确提示——粒度越细、被拒请求越多，**额外的审计日志写入也会反过来影响 Vault 的性能**。这条提醒在做规则设计时尤其重要。

### 4.2 让被拒请求"留下痕迹"：开启拒绝请求审计

默认情况下，**因为速率配额而被拒掉的请求并不会进入审计日志**——这是为了避免在大流量异常期间因疯狂写审计日志反向把 Vault 拖死。如果业务需要这些被拒请求的可追溯性，可显式将 `enable_rate_limit_audit_logging` 设为 `true`：

```shell
$ vault write sys/quotas/config enable_rate_limit_audit_logging=true
```

读取当前配额配置可验证是否生效：

```shell
$ vault read sys/quotas/config
```

预期输出会显示 `enable_rate_limit_audit_logging` 字段为 `true`。

需要顺带提一句的两个相关字段：`absolute_rate_limit_exempt_paths` 与 `rate_limit_exempt_paths` 用于把若干路径从全局速率限流中豁免出去；`enable_rate_limit_response_headers` 用于把当前剩余配额信息塞到 HTTP 响应头里返回给客户端，便于客户端做自适应退避。这两组开关都通过同一个 `sys/quotas/config` 端点配置。

### 4.3 三种典型用法

最常见的三种 `path` 用法分别对应"全集群"、"按引擎"、"按引擎下具体路径"三个粒度，覆盖了大部分生产场景。

**用法一：全集群每秒 100 个请求**——`path` 留空，对集群所有请求统一限流：

```shell
$ vault write sys/quotas/rate-limit/global-rate rate=100
```

读取该规则的输出会显示 `path: n/a`、`rate: 100`、`interval: 1`、`group_by: ip`、`type: rate-limit`。

**用法二：按引擎限流**——例如把 `transit` 引擎的访问压到"每分钟 1000 个请求"：

```shell
$ vault secrets enable transit
$ vault write sys/quotas/rate-limit/transit-limit \
    path="transit" \
    rate=1000 \
    interval=60
```

读取后 `path` 会被规整为 `transit/`、`interval=60`、`rate=1000`。

**用法三：按引擎下具体路径限流**——例如把"`orders` 这把 transit 密钥的加密请求"限到每秒 500：

```shell
$ vault write -f transit/keys/orders
$ vault write sys/quotas/rate-limit/transit-order \
    path="transit/encrypt/orders" \
    rate=500
```

输出中 `path: transit/encrypt/orders`、`rate: 500`、`interval: 1`、`group_by: ip`。

> **关于 `group_by` 与 `inheritable`**：在社区版里 `group_by` 始终为 `ip`、`inheritable` 字段虽然会出现在响应里但本质属于企业版命名空间继承能力，社区版部署中可忽略它的实际效果。

![一条 rate=100/interval=1 的全局速率配额像一个漏斗，按源 IP 分组累计请求数；窗口内第 101 个请求被立刻拒收，可选地写入审计日志](/images/ch9-production-hardening/rate-limit-funnel.png)

### 4.4 何时该用速率限流

把速率限流当成"基线加固清单的兜底"理解最为合适——在所有 baseline 项都落地之后，再为以下三类典型场景配置速率限流：

1. **全集群兜底**：所有部署都建议至少配一条 `path=""` 的全局规则，rate 设为略高于历史峰值的水平，防止极端情况下一台 Vault 被瞬时洪水流量吃满；
2. **保护昂贵的引擎**：例如 `transit/encrypt`、`pki/sign-verbatim` 这种 CPU 或加密硬件密集型路径，按引擎限流以避免被单一调用方占满；
3. **保护登录端点**：例如 `auth/userpass/login/*`、`auth/approle/login` 等，按路径限流以削弱密码爆破或凭据填充攻击的强度（与第 6.9 节的 user lockout 互补——前者从"每秒请求量"上压、后者从"连续失败次数"上锁）。

---

## 5. 本节小结

把上述内容并排放在一起即可形成一份"上线前最小检查清单"：

1. **进程与文件系统**——非 root 服务账号、最小写权限、禁 swap、禁 core dump；
2. **网络与 TLS**——端到端 TLS、TLS 1.3 优先、防火墙严格收敛入站与出站；
3. **操作系统隔离**——单租户、限制存储后端访问、节点间时钟同步；
4. **令牌与策略**——吊销初始 root token、按需生成、user lockout 复核、立刻启用审计、短 TTL、最小权限策略、定期升级、显式离职流程；
5. **扩展项按需取舍**——禁 SSH、systemd 安全开关、不可变升级、SELinux/AppArmor、调 ulimit、`disable_mlock` 取舍、独立存储分区、认证型反向代理；
6. **请求速率限流**——至少配一条全局规则；对昂贵引擎、登录端点单独配规则；如需可追溯性则开启 `enable_rate_limit_audit_logging`；社区版始终按源 IP 分组。

掌握这份清单后，可在动手实验中亲自配一条 `transit` 引擎的速率限流，触发"第 N+1 个请求被立即拒收"的现象，并验证 `enable_rate_limit_audit_logging` 开/关两种状态下被拒请求是否进入审计日志。

---

## 6. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 主机上启动一个开启了集成存储的单节点 Vault，依次完成"启用 file 审计设备 → 创建一条 `transit` 引擎的速率限流配额 → 用 `for` 循环把请求量打到限流阈值之上、亲眼看到被拒响应 → 切换 `enable_rate_limit_audit_logging` 开/关、对比审计日志是否记录被拒请求 → 再追加一条全局速率限流规则"五段操作，从终端直接观察本节正文中的关键结论。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-production-hardening" title="实验：配置请求速率限流配额并观察被拒请求" />
