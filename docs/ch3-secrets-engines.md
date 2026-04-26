---
order: 31
title: 3.1 机密引擎概览：路由、生命周期与 Barrier View
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.1 机密引擎概览：路由、生命周期与 Barrier View

> **核心结论**：Vault 本身不存储机密、不签发证书、不加密数据——这些动作
> 全部由 **机密引擎（Secrets Engine）** 这种插件完成。每个引擎被挂载到
> 一条路径前缀下，通过 Vault 内部的 Router 接收请求；每个引擎在底层存
> 储中拥有一个**以 UUID 为根的私有"chroot"**（Barrier View），彼此之
> 间数据完全隔离。理解这一层路由 + 隔离模型，是后续学习 KV、Database、
> PKI、Transit 等具体引擎的共同基础。

参考：
- [Secrets Engines — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets)
- [vault secrets enable](https://developer.hashicorp.com/vault/docs/commands/secrets/enable)
- [vault secrets disable](https://developer.hashicorp.com/vault/docs/commands/secrets/disable)
- [vault secrets move](https://developer.hashicorp.com/vault/docs/commands/secrets/move)
- [vault secrets tune](https://developer.hashicorp.com/vault/docs/commands/secrets/tune)

---

## 1. 心智模型：Vault 是一个"装满插件的虚拟文件系统"

Vault 启动后并不知道任何具体的"机密"概念。**所有"读写一条机密"的能力
都由机密引擎插件提供**，Vault 只负责三件事：

1. 路由请求到正确的引擎实例（按路径前缀匹配）
2. 把每次请求过一遍 Auth → Policy → Audit 三道关
3. 把引擎产出的字节流加密后写入存储后端

> 文档对引擎给的定义非常直白：
>
> > Secrets engines are components which store, generate, or encrypt data ...
> > To the user, secrets engines behave similar to a virtual filesystem,
> > supporting operations like read, write, and delete.

也就是说——对调用者来说，每个挂载点就是一个"目录"，引擎决定这个目录
里能 read / write / list / delete 什么、操作的语义是什么。`secret/` 下
的 write 是"存一条 KV"；`database/` 下的 read 是"立刻给我生成一对临
时账号"；`transit/` 下的 write 是"用这把密钥加密下面这段明文"。

![Vault 核心 + 机密引擎插件的心智模型](/images/ch3-secrets-engines/core-vs-engines.png)

---

## 2. 功能光谱：四类典型引擎

虽然每个引擎自定义自己的路径与语义，但按"对数据做什么"可以分成四个大
类，覆盖 Vault 90% 的使用场景：

| 类型 | 代表引擎 | 行为 |
| --- | --- | --- |
| **纯存储类** | KV v2、Cubbyhole | 把字节存进来，原样取出去（带版本/审计） |
| **动态凭据类** | Database、AWS、Azure、SSH | 收到读请求时**实时**向后端创建一个临时账号，附带 Lease |
| **加密即服务（EaaS）** | Transit | 不存数据，只用内部托管的密钥对外加解密、签名、HMAC |
| **证书签发类** | PKI | 充当内部 CA，签发短生命周期的 X.509 证书；与 ACME 协议结合可以做到全自动化 |

特殊一点的是 `identity/`、`sys/`、`cubbyhole/` 这几个**内置引擎**——它
们随 Vault 启动自动挂载，不能 disable，是 Vault 自身机能的一部分（参考
2.5 章 Identity 与 2.7 章 Cubbyhole/Response Wrapping）。

![四类机密引擎对比 + 三个内置引擎](/images/ch3-secrets-engines/engine-spectrum.png)

> **教学路径**：本章接下来的小节会逐个挑选这四类的代表引擎进行实战
> （具体引擎选讲清单见课程大纲），但所有引擎都遵循本节描述的同一套
> 路由 / 生命周期 / 隔离模型。

---

## 3. 生命周期四件套：enable / disable / move / tune

文档给出的引擎管理动作只有四个，**每一个的副作用都需要被精确理解**。

### 3.1 `enable`：启用引擎

```bash
# 默认路径（与类型同名）
vault secrets enable kv-v2          # 挂在 kv-v2/
vault secrets enable -version=2 kv  # 等价写法，挂在 kv/

# 自定义路径（推荐）
vault secrets enable -path=team-a-kv -version=2 kv
vault secrets enable -path=prod-pki  pki
```

启用之后，路由表里就多了一条 `team-a-kv/` → `<新引擎实例>` 的映射。

### 3.2 `disable`：**销毁式**卸载

```bash
vault secrets disable team-a-kv/
```

> 文档原话：
>
> > When a secrets engine is disabled, all of its secrets are revoked
> > (if they support it), and **all the data stored for that engine in
> > the physical storage layer is deleted**.

也就是 `disable` 不是"暂停"——它会：

1. 撤销该引擎下所有 Lease（动态凭据立即作废）
2. **永久删除**该引擎在底层存储的所有数据块
3. 从路由表中摘除该挂载

⚠️ **生产环境绝不能拿 `disable` 当"重启引擎"用**。需要"换路径"时一定走 §3.4 的 `move`。

### 3.3 `tune`：在线调整运行参数

```bash
vault secrets tune \
  -default-lease-ttl=1h \
  -max-lease-ttl=24h \
  team-a-kv/
```

`tune` 改的是引擎的**运行配置**（默认/最大 Lease TTL、可见的 HTTP
header、密封 wrap TTL 等），不影响已经存进去的数据。可以反复执行。

### 3.4 `move`：原子重命名挂载路径

```bash
vault secrets move legacy-kv/ archive/
```

`move`（底层 API `POST /sys/remount`）只动路由表的指针，**底层加密
数据一字节都不复制**——这是为什么它能在毫秒级完成。但有两个副作用：

- 该引擎下所有动态 Lease 会被撤销（因为 Lease 与签发时的路径绑定）
- **Policy 中引用旧路径的规则不会自动跟着改**，必须手动同步

`move` 的完整深度剖析放在 [5.7 Mount Migration](/ch5-mount-migration)
章节，本节只需要知道它的存在与"它不会自动改 Policy"这一点即可。

---

## 4. 路径约束：两条容易踩坑的硬性规则

### 4.1 路径**大小写敏感**

```bash
vault secrets enable -path=kv kv-v2     # 实例 A
vault secrets enable -path=KV kv-v2     # 实例 B —— 与 A 完全独立！
```

文档原话：

> The path where you enable secrets engines is **case-sensitive**.
> For example, the KV secrets engine enabled at `kv/` and `KV/` are
> treated as two distinct instances of KV secrets engine.

写在 Policy 或应用代码里时大小写要严格对齐——把 `KV/data/foo` 写成
`kv/data/foo`，得到的是 403 而不是数据。

### 4.2 挂载点之间**不能互为前缀**

```bash
vault secrets enable -path=foo/bar kv-v2   # OK
vault secrets enable -path=foo/baz kv-v2   # OK ——  和 foo/bar 平级，互不影响
vault secrets enable -path=foo     kv-v2   # ❌ 失败：foo 是 foo/bar 的前缀
```

文档原话：

> You cannot have a mount which is prefixed with an existing mount.
> The second is that you cannot create a mount point that is named as
> a prefix of an existing mount.

所以**同级目录可以无限多**，但不能让一个挂载点"包住"另一个挂载点。
这条规则保证了 Router 在分发请求时永远只有一条匹配路径，不会出现
歧义。

---

## 5. 同类型引擎多次挂载：天然的多租户隔离

利用 §3.1 的自定义路径机制，可以把同一种引擎挂在不同路径上，互相完全
独立。这是 Vault 内最常用的多租户模式：

```bash
# 给开发团队和生产团队各挂一个 KV
vault secrets enable -path=team-dev-kv  -version=2 kv
vault secrets enable -path=team-prod-kv -version=2 kv

# 给两个独立业务线各挂一套 PKI
vault secrets enable -path=internal-pki  pki
vault secrets enable -path=customer-pki  pki

# 多挂载在 Policy 中天然做权限分离
path "team-dev-kv/data/*"  { capabilities = ["read", "create", "update"] }
path "team-prod-kv/data/*" { capabilities = ["read"] }
```

每个挂载点拥有独立的：

- 数据目录（见下一节 Barrier View）
- Tune 配置（TTL 等）
- 角色定义（Database 的 role、AppRole 的 role 等）
- Accessor（不可变标识，迁移路径也不变）

**这是 Vault 实现"按团队/按环境隔离"最常用的手法**——比起依赖 Policy
做事后限制，物理隔离一开始就把权限边界画死了。

---

## 6. Barrier View：每个引擎的"chroot"沙箱

理解了"多个挂载点共存"以后，下一个自然的问题是：**它们在底层存储里
怎么互不打架？**

文档给出的答案非常优雅——**Barrier View**：

> Secrets engines receive a barrier view to the configured Vault physical
> storage. This is a lot like a chroot.
>
> When a secrets engine is enabled, a random UUID is generated. This
> becomes the data root for that engine. Whenever that engine writes to
> the physical storage layer, it is **prefixed with that UUID folder**.
> Since the Vault storage layer doesn't support relative access (such
> as `../`), this makes it impossible for an enabled secrets engine to
> access other data.

形式化画出来：

```
         ┌─────────────────────────────────────────┐
         │         Storage Backend (Raft)          │
         │                                         │
         │   logical/<UUID-A>/...   ← team-dev-kv  │
         │   logical/<UUID-B>/...   ← team-prod-kv │
         │   logical/<UUID-C>/...   ← internal-pki │
         │   logical/<UUID-D>/...   ← customer-pki │
         │                                         │
         │   每个 UUID 对一个引擎实例可见，          │
         │   引擎插件代码无法越界访问其他 UUID       │
         └─────────────────────────────────────────┘
```

由此可以推出几个**性质**：

1. **路径名换了，UUID 不变**——Vault 提供一条 `vault secrets move A/ B/`
   命令（详细原理留到 5.7 章 Mount Migration 详讲），它只是把**路由
   表**里 `A/` 这个 key 改名成 `B/`，背后绑定的引擎实例与它的 UUID 子
   树原封不动——所以不需要复制任何加密字节，毫秒级完成。这意味着：
   **挂载路径只是路由表里一个可变的标签，UUID 才是引擎实例真正不可变
   的身份**。
2. **plugin 故障半径被限制在自己的 UUID 子树里**——即便某个第三方插件
   存在 bug 或恶意代码，它在 Go API 层就拿不到其他引擎的存储句柄，
   "横向移动"被釜底抽薪式地切断。
3. **`disable` 删除的就是该引擎的 UUID 子树**——这也是为什么
   `disable` 是不可逆的；UUID 子树被清空后，即使再以同名路径
   `enable`，得到的也是一个全新 UUID 的空引擎。

> **教学价值**：每次你执行 `vault secrets list -detailed` 看到那一列
> `Accessor` 与 `UUID`，你看到的就是 Barrier View 隔离的物理证据。

---

## 7. 与上层 Policy / 下层 Storage 的关系

把整张图拼起来，机密引擎在 Vault 内部承担了"数据平面"的角色。可以
把一次请求想象成一个工人进工厂上班的全过程：他先在大门口被三道闸口
（Auth / Policy / Audit）依次校验，再被分流盘（Router）指派到对应的
车间（机密引擎），车间里的工人按"工号牌"（UUID）取/存自己货架上的
箱子，最后所有要离开车间的字节都得先穿过一道加密屏障（Barrier），
才能落到最右边的仓库（Storage Backend）里：

![Vault 一次请求的全链路：工厂流水线视角](/images/ch3-secrets-engines/request-pipeline.png)

几个一定要记住的关联：

- **Policy 路径是按挂载点写的**：`path "team-prod-kv/data/db/*"`
  里的 `team-prod-kv/` 是挂载路径而不是引擎类型，迁移路径后 Policy
  必须手动同步（这是 5.7 章详讲的内容）
- **Lease 与挂载路径绑定**：Database 引擎签发的临时账号 Lease ID 形如
  `database/creds/readonly/abc...`，迁移挂载点后旧 Lease 全部作废
- **Audit 日志记录的是路径**：审计日志里看到的 `request.path` 是当时
  生效的挂载路径，配合 Accessor 才能精确追踪到具体引擎实例

---

## 8. 一张速查表

| 你想做什么 | 命令 | 副作用 |
| --- | --- | --- |
| 启用一个新引擎 | `vault secrets enable -path=X T` | 创建新 UUID 子树 |
| 临时修改 TTL 等参数 | `vault secrets tune ...` | 数据零影响 |
| 改路径名 | `vault secrets move A/ B/` | 撤销 Lease；Policy 不自动改 |
| 卸载且彻底销毁数据 | `vault secrets disable X/` | **不可逆**——UUID 子树整体删除 |
| 查看所有挂载（含 UUID） | `vault secrets list -detailed` | 只读 |
| 查看引擎自定义路径 | `vault path-help X/` | 只读 |

---

## 9. 实验室预告

本节配套的动手实验把上面六个关键设计跑一遍：

1. **挂载与多实例**：在不同路径下启用两个 KV v2，观察 Accessor 与
   UUID，验证它们是完全独立的两个实例
2. **大小写与前缀冲突**：亲手触发"路径大小写不一致"和"挂载点互为
   前缀"两条硬性规则
3. **`tune` vs `disable`**：用 `tune` 在线修改 TTL（数据零影响），
   再演示 `disable` 把整个 UUID 子树彻底抹除
4. **Barrier View 的物理证据**：通过对比两个 KV 实例的 Accessor 与
   `vault secrets list -detailed` 的输出，证明它们在存储层是两个
   完全不相通的 UUID 子树

进入实验前请确认你已经理解 §3.2（disable = 销毁式卸载）、§4（路径
大小写敏感 + 前缀冲突）、§6（Barrier View 的 UUID-chroot 模型）这三段。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-secrets-engines" title="实验：机密引擎挂载、生命周期与 Barrier View 隔离" />

## 参考文档

- [Secrets Engines](https://developer.hashicorp.com/vault/docs/secrets)
- [vault secrets enable](https://developer.hashicorp.com/vault/docs/commands/secrets/enable)
- [vault secrets disable](https://developer.hashicorp.com/vault/docs/commands/secrets/disable)
- [vault secrets tune](https://developer.hashicorp.com/vault/docs/commands/secrets/tune)
- [vault secrets move](https://developer.hashicorp.com/vault/docs/commands/secrets/move)
- [Mount Migration（深度剖析见 5.7）](https://developer.hashicorp.com/vault/docs/concepts/mount-migration)
