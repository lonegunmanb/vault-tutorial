---
order: 34
title: 3.4 Cubbyhole 机密引擎：每个 Token 一个私人储物柜
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.4 Cubbyhole 机密引擎：每个 Token 一个私人储物柜

> **核心结论**：Cubbyhole 是 Vault 内置的、**绑定在 Token 维度**的微
> 型存储引擎。它最大的特点不是"能存什么"——它存的就是任意 KV 字段，
> 跟 KV v1 长得一模一样——而是它**存在哪儿**：每一份数据都被关在
> 当前 Token 的私有命名空间里，**任何其它 Token（包括 root）都看不
> 见、读不到**；当 Token 过期或被 revoke，这块储物柜会被原子销毁。
> 这一节我们梳理清楚：为什么 Cubbyhole 在挂载层面就被官方标记为"不
> 能 disable / 不能 move / 不能再次 enable"、它和 KV v1/v2 的本质区
> 别在哪里、以及它如何成为 [2.7 章](/ch2-response-wrapping)
> Response Wrapping 的底层载体。

参考：
- [Cubbyhole — Vault Secrets Engines Docs](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole)
- [Cubbyhole API](https://developer.hashicorp.com/vault/api-docs/secret/cubbyhole)
- [Response Wrapping 概念](/ch2-response-wrapping)

---

## 1. 为什么需要"按 Token 隔离"的存储

KV（不论 v1 还是 v2）解决的是**全局共享的机密数据**：路径写在哪，
谁有 Policy 谁就能读。但有一类小数据不适合走这个模型：

- 一个**临时脚本**想把中间结果暂存几分钟，不想让任何别的人看到、也不
  想留下任何长期残留
- 一段**转手数据**：A 系统生成、希望 B 系统取走一次后即灭；任何中间
  人（包括 root）都不该能截胡
- **Response Wrapping 的载体**：Vault 把"被包起来的真实响应"暂存到
  某个地方，只交出一个一次性 wrapping token——这个"地方"不能是普通
  KV，否则任何 root 都能直接去读

Cubbyhole 就是为了这类需求存在的。它的核心不变量只有一条：

> **`cubbyhole/<path>` 的可见性等于"持有这个 Token"——别无其它授权
> 维度**。

把这条记牢，下面所有特殊行为都会变得自然。

---

## 2. 挂载层面的"三不允许"

[官方文档](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole#setup)
里直接写了：

> The `cubbyhole` secrets engine is enabled by default. It cannot be
> disabled, moved, or enabled multiple times.

挨个解释一下"为什么"：

| 行为 | 是否允许 | Vault 真实报错 / 原因 |
| --- | --- | --- |
| **默认挂载在 `cubbyhole/`** | 是（不可改） | Token 体系的基础设施依赖它，初始化时就必须存在 |
| `vault secrets disable cubbyhole/` | ❌ | `cannot unmount "cubbyhole/"`——禁用等于把所有 Token 当前的暂存数据 + 未拆封的 wrapping token 全部打爆，会击穿 Token 体系 |
| `vault secrets move cubbyhole/ → other/` | ❌ | `cannot remount "cubbyhole/"`——内部硬编码 `cubbyhole/response` 等系统路径，搬走会让 Response Wrapping 找不到家 |
| `vault secrets enable -path=cb cubbyhole` | ❌ | `mount type of "cubbyhole" is not mountable`——"按 Token 隔离"在底层是单例实现，多挂一份没意义 |
| `vault secrets tune cubbyhole/` | ❌ | `cannot tune "cubbyhole/"`——连常规调参也被堵；Cubbyhole 是"出厂即定型"的特殊存在 |

> 你能对它做的只有两件事：**读它的元数据**（`vault read
> sys/mounts/cubbyhole`）和**通过自己的 Token 读写它的数据**——所有
> 挂载点级别的操作（enable/disable/move/tune）全部锁死。

这与 [3.1 章](/ch3-secrets-engines)讲的"机密引擎是挂在路由表上的可插
拔插件"那个通用心智模型是个例外——Cubbyhole 是**唯一**这样被特殊对
待的内置引擎，背后原因就是它承载的不是业务数据，而是 Token 体系自身
的运行时状态。

---

## 3. 与 KV v1 / KV v2 的对比

很多人第一次用 Cubbyhole 会问："这跟 `kv put` 看起来不就是一样吗？"
区别全在**可见性**和**生命周期**这两个维度上：

| 维度 | KV v1 | KV v2 | Cubbyhole |
| --- | --- | --- | --- |
| 默认挂载 | ❌（要手动 enable） | ❌（要手动 enable） | ✅ 内置在 `cubbyhole/` |
| 可见性单位 | Policy 控制的全局路径 | Policy 控制的全局路径（带 `data/`） | **Token 私有**：只有写入时所用的 Token 能看 |
| 跨 Token 共享 | ✅（凭 Policy） | ✅（凭 Policy） | ❌ **绝对不行**——root 也不行 |
| 版本历史 | ❌ | ✅ 多版本 + soft delete | ❌（写入直接覆盖） |
| TTL / lease | ❌ 永久 | ❌ 永久（除非显式 destroy） | ⏱ **绑定 Token 寿命**：Token 一灭即灭 |
| Policy 怎么写 | `kv/foo` | `kv/data/foo` | 一般**不需要写**——见 §6 |
| 适用场景 | 简单全局机密 | 需要历史 / 软删的全局机密 | 临时暂存 / Response Wrapping 载体 |

记忆口诀：**KV 是"档案柜"（按路径找），Cubbyhole 是"钥匙串挂的私人储
物柜"（按 Token 找，钥匙没了柜子就拆了）**。

---

## 4. 基本用法

[官方文档](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole#usage)
给的例子用 `vault write` / `vault read`，因为 Cubbyhole 是 KV v1 风
格的"裸路径"，**不要**用 `vault kv put`（那是 KV 引擎专属命令）。

```bash
# 写
vault write cubbyhole/my-secret my-value=s3cr3t

# 读
vault read cubbyhole/my-secret

# 列
vault list cubbyhole/

# 删
vault delete cubbyhole/my-secret
```

写入后立刻读，是当前这个 Token 在自己的命名空间里读自己的数据——所
以不需要任何额外 Policy 配置就能成功（默认 token policy 已经允许，
见 §6）。

---

## 5. Token 隔离：本节的"压轴"

这是 Cubbyhole 区别于其它一切引擎的核心，也是最容易在"我以为我懂"
之后被打脸的地方。三条规则全部成立：

1. **同一个 Token 多次访问**——能看到自己之前写的所有数据
2. **不同的 Token**（哪怕是父子关系、哪怕另一个是 root）——**完全
   看不到**对方写的任何东西
3. **Token 过期或 `vault token revoke` 之后**——这个 Token 写过的
   全部 cubbyhole 数据被 Vault 原子清空，无法恢复

第 2 条尤其反直觉。常见的两类误会：

- "我用 root 创了个子 token，子 token 写的东西，root 应该能看见
  吧？"——**不能**。父 token / root 与子 token 之间在 Cubbyhole 这
  个引擎内部是平行的隔离命名空间。
- "我把 token accessor / token ID 拷给同事，他用 `vault token
  lookup` 能看到这个 token 的属性，那他也应该能看到这个 token 的
  cubbyhole 吧？"——**不能**。Lookup 看的是 Token 元数据，不是
  Cubbyhole 数据；要"看"必须**用这个 token 本人去登录**。

这条隔离不是 Policy 加上去的，是 Cubbyhole 引擎在底层用 Token ID 直
接做命名空间分片实现的——**Policy 写得再开放也无法跨 Token 看见对
方的 cubbyhole**。本章实验 Step 2 会让你亲手验证这一点。

---

## 6. Policy 与 Cubbyhole

打开 Vault 自带的 `default` Policy，会看到这一段：

```hcl
# 摘自 Vault 默认 default policy
path "cubbyhole/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

也就是说：**只要 Token 绑了 default policy（默认就绑了），就拥有自己
cubbyhole 的全套权限**——你不需要再写一份 KV-style 的"哪个用户能读
哪个路径"的 Policy。Token 隔离已经把"谁能看"那一维度处理掉了。

什么时候需要动这块 Policy？**只有想"剥夺"的时候**：

- 用 `no_default_policy=true` 创建 Token，让它彻底没有 cubbyhole 权
  限——主要用于 Response Wrapping 流程中那种"一次性扔出去就作废"
  的纯传递场景
- 在自定义 Policy 里把 `cubbyhole/*` 的 capability 缩到 `["read"]`
  之类——理论上可行，实战上几乎没人用，因为 cubbyhole 本来就只能影
  响这一个 Token 自己

---

## 7. 与 Response Wrapping 的关系（[2.7 章](/ch2-response-wrapping)的回收）

Response Wrapping 流程为什么"一次拆封即作废 + 内容只能看一次"？因为
真实响应根本没在交换通道里露面——Vault 把它**塞进了一个新建一次性
Token 的 cubbyhole 里**：

```
请求方：vault read -wrap-ttl=5m secret/data/db-password
                      │
                      ▼
        Vault 内部：
          1. 真的去读 secret/data/db-password 拿到 {password: ...}
          2. 新建一个生命周期 = wrap-ttl 的 wrapping token
          3. 把响应 JSON 写进 cubbyhole/response
             —— 命名空间 = 这个新 wrapping token
          4. 只把 wrapping token 的 ID 返回给请求方
                      │
                      ▼
请求方拿到：wrapping_token = s.xxxx, ttl = 5m
                      │
                      ▼
拆封方：vault unwrap s.xxxx
        → Vault 用 s.xxxx 登录 → 读 cubbyhole/response → 拿到原响应
        → 立即 revoke s.xxxx → cubbyhole 整体销毁
```

这条流水线里，**Cubbyhole 的"按 Token 隔离 + Token 灭则数据灭"**正
好同时给了两个保证：

- **机密性**：除了持有 wrapping token 的人，**没有任何途径**能从
  Vault 把那份响应读出来——root 也不行，因为 root 的 Token 不是这个
  wrapping token，按 §5 的隔离规则就是看不到
- **一次性**：拆封即 revoke wrapping token，Cubbyhole 同步销毁——之
  后的"重放"或"二次窃取"再无可能

明白了这一层，2.7 章那句"Response Wrapping 用 Cubbyhole 当底层载体"
就不再是黑箱描述，而是字面意义上的"`cubbyhole/response` 这个路径"。

---

## 8. 适用场景与反模式

### ✅ 合适的用法

- **临时脚本中转**：一个 CI 步骤生成的中间凭据，暂存在执行该步骤的
  Token 的 cubbyhole 里，下一步同一 Token 取走、流程结束 Token revoke
  自动清场
- **Response Wrapping**：见 §7
- **个人 Token 暂存**：开发者手动 `vault login` 之后想存几条只在本次
  会话有效的标记位（比如 `vault write cubbyhole/notes today=...`）

### ❌ 不要这样用

- **当 KV 用**：因为 cubbyhole 没版本、没跨 Token 共享、Token 灭即
  灭——拿来存"持续业务用的密码"几乎一定会出现"那个写入的 Token 过
  期了，所有人都读不到了"的事故
- **试图用它做团队共享**：根本做不到，§5 已经讲过
- **依赖 cubbyhole 跨服务传递数据但不用 Response Wrapping**：你会发
  现自己在重新发明一个不安全版本的 wrap/unwrap——直接用
  `-wrap-ttl=` 即可，不要绕路

---

## 9. 路径与 Policy 速查

| 想做的事 | 路径 | 备注 |
| --- | --- | --- |
| 写 / 读 / 删自己的 cubbyhole 数据 | `cubbyhole/<任意路径>` | default policy 已经放开，无需额外授权 |
| 列出自己 cubbyhole 下的 keys | `cubbyhole/` | 同上 |
| 看 Response Wrapping 的载体路径 | `cubbyhole/response` | Vault 内部约定；直接读在 1.19+ 会报 deprecation，生产请用 `vault unwrap` / `sys/wrapping/unwrap` |
| disable / move / 二次 enable / tune | — | **全部禁止**，见 §2 |
| 跨 Token 读对方的 cubbyhole | — | **没有任何 Policy 写法能做到** |

---

## 10. 与其它章节的衔接

- **[2.4 Token](/ch2-auth-tokens)**：Cubbyhole 的隔离单位就是 Token；
  Token 树状继承 / revoke 级联那一套规则在 Cubbyhole 上是**字面**生
  效的——父 Token 被 revoke，所有子 Token 的 cubbyhole 都跟着灭
- **[2.7 Response Wrapping](/ch2-response-wrapping)**：本章 §7 把那
  一节的"黑箱"解开
- **[3.1 机密引擎概览](/ch3-secrets-engines)**：Cubbyhole 是该章
  "通用挂载模型"的**唯一例外**——记住这个例外比记住通用规则更重要
- **[3.2 KV v2](/ch3-kv-v2)**：Cubbyhole ≈ "KV v1 + Token 隔离 - 跨
  Token 共享 - 永久存储"。两者解决的是完全不同的问题，不要混用

---

## 11. 互动实验

本节配套的 Killercoda 实验在一个 Dev 模式 Vault 上把上述所有论断都
亲手跑一遍：

- **Step 1**：观察 cubbyhole 默认就在挂载列表里，亲手验证它**不能**
  被 disable / move / 二次 enable / 甚至 tune，全部报错信息照原样复原
- **Step 2**：用 root token 写一份数据，再创建一个子 token、用它登录
  查看，**确认根本看不到**——Token 隔离的字面演示
- **Step 3**：在一个短 TTL 的 token 里写 cubbyhole，看它过期后数据被
  整体销毁；再 `vault token revoke` 另一个 token，看 cubbyhole 同步
  消失
- **Step 4**：用 `-wrap-ttl=` 走一遍 Response Wrapping 流程，用
  wrapping token **直接 `vault read cubbyhole/response`**，把 §7 那张
  图字面验证一遍（Vault 1.19+ 在这条命令上会同时点亮 deprecation
  警告：生产里请用 `vault unwrap` / `sys/wrapping/unwrap`）

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-cubbyhole" title="实验：Cubbyhole 引擎与 Token 隔离全流程" />
