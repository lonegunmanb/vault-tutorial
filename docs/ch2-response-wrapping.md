---
order: 27
title: 2.7 响应封装（Response Wrapping）与防篡改一次性数据传递
group: 第 2 章：核心机制与高级状态机概念
group_order: 20
---

# 2.7 响应封装（Response Wrapping）与防篡改一次性数据传递

> **核心结论**：Response Wrapping 是 Vault 的"密封快递"机制——调用任何
> API 时加一个 `-wrap-ttl` 参数，Vault 就不把真正的数据直接返回给你，而是
> 把数据塞进一个**一次性单用 token 绑定的 cubbyhole**，只把这个 wrapping
> token 给你。收件方拿到 token 后用 `vault unwrap` 拆封，数据只能拆一次——
> **第二次拆就报错**，调度方立刻能感知到有人截获并提前拆封了。

参考：
- [Response Wrapping — Concepts](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping)
- [Cubbyhole Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole)

---

## 1. 为什么需要 Response Wrapping

考虑一个最常见的生产场景：运维人员（Operator）从 Vault 拿到一份临时
数据库凭据，然后通过 Slack、邮件或配置管理工具把密码传给目标服务器。
这条传输链路上存在三个致命风险：

| 风险 | 描述 |
| --- | --- |
| **日志泄露** | 传输链条上任何中继组件的日志都可能记录明文密码 |
| **中间人截获** | 攻击者截获密码后静默使用，发送方和接收方都无法察觉 |
| **凭据长期暴露** | 从签发到消费之间的时间窗口越长，凭据暴露面越大 |

Response Wrapping 一次性解决全部三个问题：

- **遮蔽**（Cover）：传输链上流动的不是真正的密码，而只是一个对密码的
  "引用"——wrapping token。即使日志记录了这个 token，它也不是密码本身；
- **篡改/截获检测**（Malfeasance Detection）：wrapping token **只能被
  拆封一次**。如果收件方发现 unwrap 失败（token 已被使用或已失效），
  说明**有人提前截获并拆封了**——应立刻触发安全事件响应；
- **时限控制**（Lifetime Limitation）：wrapping token 有独立于被包装数
  据的 TTL，通常设置得非常短（30 秒 ~ 几分钟），过期未拆即销毁。

---

## 2. 底层机制：单用 token + cubbyhole

Response Wrapping 并不是一套独立的加密系统，而是巧妙复用了 Vault 已有
的两个原语——**临时 token** 和 **cubbyhole 引擎**。

当客户端在请求中附带 `X-Vault-Wrap-TTL`（CLI 里是 `-wrap-ttl`）时：

1. Vault 正常执行请求，拿到原始响应；
2. 生成一个**一次性单用 token**（TTL 由客户端指定）；
3. 把原始响应序列化后存入该 token 私有的 cubbyhole（`cubbyhole/response`）；
4. 返回给客户端的**不是原始响应**，而是一个包含了 wrapping token 信息
   的新响应。

```
  Operator                   Vault                          受保护的 cubbyhole
  ────────                   ─────                          ────────────────
  vault kv get               ①正常执行 kv get
    -wrap-ttl=60s            ②拿到实际数据 {"password":"xxx"}
    secret/db                ③生成临时 token hvs.wrap-XXXX (TTL=60s)
         │                   ④把 {"password":"xxx"} 写入 hvs.wrap-XXXX 的 cubbyhole
         │                   ⑤返回：{wrap_info: {token: hvs.wrap-XXXX, ttl: 60}}
         ▼
  收到 wrapping token
  （不是密码本身）
         │
         │ 传给目标服务器
         ▼
  目标服务器执行
  vault unwrap hvs.wrap-XXXX
         │                   ⑥验证 token → 读 cubbyhole → 返回原始数据
         │                   ⑦立刻吊销 hvs.wrap-XXXX（一次性）
         ▼
  拿到 {"password":"xxx"}
```

**关键性质**：

- **cubbyhole 是 token 私有的**——每个 token 有且只有自己的 cubbyhole
  空间，其他 token（包括 root token）都无法访问；
- **token 被吊销 = cubbyhole 被销毁**——unwrap 后 token 立刻作废，数据
  随之烟消云散；
- **TTL 过期 = 自动销毁**——即使没人来拆封，超时后 token 自动过期，
  cubbyhole 里的数据同样彻底清除。

---

## 3. wrapping token 返回的元数据字段

调用 wrap 后返回的 `wrap_info` 对象包含以下字段：

| 字段 | 含义 |
| --- | --- |
| `token` | wrapping token 的 ID，用于 unwrap |
| `accessor` | wrapping token 的 accessor（可用于查看状态但不能拆封） |
| `ttl` | wrapping token 剩余有效秒数 |
| `creation_time` | wrapping token 的创建时间 |
| `creation_path` | **触发包装的原始 API 路径**——接收方可用此验证数据来源 |
| `wrapped_accessor` | 如果被包装的数据本身是一个 token，这里是那个 token 的 accessor |

其中 `creation_path` 是防篡改验证的关键——接收方在 unwrap **之前**先
做 lookup，检查 `creation_path` 是否符合预期（例如应该是
`secret/data/db` 而不是 `cubbyhole/` 或 `sys/wrapping/wrap`），可以防
止攻击者用假数据重新包装后冒充。

---

## 4. 四个核心操作：wrap / lookup / unwrap / rewrap

| 操作 | API 路径 | CLI | 用途 |
| --- | --- | --- | --- |
| Wrap | `sys/wrapping/wrap` | `vault write -wrap-ttl=60s sys/wrapping/wrap key=val` | 包装任意自定义数据 |
| Lookup | `sys/wrapping/lookup` | `vault token lookup -accessor <acc>` 或 `vault write sys/wrapping/lookup token=<tok>` | 检查 wrapping token 状态，**不消耗** token |
| Unwrap | `sys/wrapping/unwrap` | `vault unwrap <token>` | 拆封，**只能用一次** |
| Rewrap | `sys/wrapping/rewrap` | `vault write sys/wrapping/rewrap token=<tok>` | 续命——用旧 wrapping token 换一个新的（数据不变） |

注意：

- 所有请求都可以加 `-wrap-ttl` 触发 response wrapping，不局限于
  `sys/wrapping/wrap`。例如 `vault kv get -wrap-ttl=30s secret/foo` 把
  KV 读取的结果包装起来；`vault token create -wrap-ttl=120s` 把新 token
  包装起来；
- `sys/wrapping/lookup` **不需要认证**（unauthenticated）——wrapping
  token 持有者总是可以检查自己 token 的元数据；
- `rewrap` 适合长期保管但需要定期轮转 token 的合规场景——不拆封数据
  本身，只换一个新 wrapping token。

---

## 5. 与 ACL Policy 的联动：强制 wrapping

2.6 节 §3.2 提到过，policy 里可以用 `min_wrapping_ttl` / `max_wrapping_ttl`
**强制**某条路径上的响应必须被包装：

```hcl
path "auth/approle/role/my-role/secret-id" {
  capabilities      = ["create", "update"]
  min_wrapping_ttl  = "1s"     # > 0 即强制必须 wrap
  max_wrapping_ttl  = "90s"
}
```

设了 `min_wrapping_ttl >= 1s` 后，如果调用方没有附带 `-wrap-ttl` 或者
给的 TTL 不在 [min, max] 区间内，**请求直接被 403 拒绝**。

这是 **AppRole 安全交付 SecretID** 的标准生产做法——确保 SecretID 永远
不会以明文出现在任何响应体中。

---

## 6. 典型应用场景

### 6.1 安全交付 AppRole SecretID（分发"第零号机密"）

```
  CI 调度器（持有 admin token）            目标 Runner
  ─────────────────────────                ──────────
  vault write -wrap-ttl=120s               收到 wrapping token
    -f auth/approle/role/ci/secret-id      vault unwrap → 拿到 secret_id
         │                                 vault write auth/approle/login
         └── 只传 wrapping token ─────────→   role_id=...
             （不是 SecretID 本身）            secret_id=<刚拆出来的>
```

### 6.2 安全分发初始 token 给新服务器

```
  运维人员                                  新启动的 VM
  ────────                                 ──────────
  vault token create                       收到 wrapping token
    -wrap-ttl=300s                         vault unwrap → 拿到服务 token
    -policy=app-db                         开始用这个 token 访问 Vault
```

### 6.3 跨团队安全传递一次性敏感数据

```
  安全团队                                  开发团队 Alice
  ─────────                                ────────────
  vault write -wrap-ttl=600s               收到 wrapping token
    sys/wrapping/wrap                      vault unwrap → 拿到 TLS 私钥
    cert=@tls.key                          第二次 unwrap → 失败（已被拆过）
```

---

## 7. 安全验证最佳实践

接收方拿到 wrapping token 后，正确的验证流程是：

1. **未收到 token ？** → 可能被中间人截获并阻断了传递 → **立刻报警**；
2. **lookup token** → 检查是否已过期或已被使用（invalid） → 如果无效
   → **触发安全调查**（不一定是攻击——也可能是超时，但必须查清）；
3. **检查 `creation_path`** → 是否与预期的来源路径匹配？如果路径是
   `cubbyhole/` 或 `sys/wrapping/wrap`（而你期望的是 `secret/data/...`），
   说明可能有人**读取了原始数据后重新包装**成假 token → **立刻报警**；
4. **unwrap** → 如果失败 → **触发安全调查**；
5. **成功** → 消费数据。

---

## 8. cubbyhole 引擎 vs response wrapping 的区别

初学者容易混淆"直接写 cubbyhole"和"response wrapping"——它们底层都
用 cubbyhole，但使用场景完全不同：

| 维度 | 直接写 cubbyhole | Response Wrapping |
| --- | --- | --- |
| 操作 | `vault write cubbyhole/my-secret key=val` | 任何 API 加 `-wrap-ttl` |
| token 归属 | 数据属于**调用者自己的** cubbyhole | 数据属于**新生成的一次性 token** 的 cubbyhole |
| 谁能读 | 只有调用者自己 | 只有 wrapping token 的持有者 |
| 一次性 | 不是——调用者可反复读写 | **是**——unwrap 即销毁 |
| 传递语义 | 自用私有存储 | 跨方安全传递 |

简言之：cubbyhole 是"保险箱"，response wrapping 是"密封快递"。

---

## 9. 实验室预告

本节配套的动手实验把上面 8 节内容跑一遍：

1. **基础包装与拆封**：用 `-wrap-ttl` 包装一个 KV 机密，验证 unwrap
   只能拆一次，第二次拆就报错；
2. **lookup 检查与 creation_path 验证**：拆封前先 lookup，确认 wrapping
   token 的来源路径和创建时间；
3. **TTL 过期自动销毁**：用一个极短 TTL（5 秒）演示过期后 unwrap 失败；
4. **Policy 强制 wrapping**：写一条带 `min_wrapping_ttl` 的 policy，验
   证不带 `-wrap-ttl` 的请求被 403 拒绝；
5. **完整场景：AppRole SecretID 安全交付**：综合 AppRole + response
   wrapping，走一遍"调度方包装 SecretID → Runner 拆封登录"的完整
   生产流程。

进入实验前请回顾 §2（cubbyhole 是 token 私有的）、§5（policy 强制
wrapping 的 min/max TTL 语法）和 §7（验证四步法）。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch2-response-wrapping" title="实验：响应封装（Response Wrapping）防篡改一次性数据传递" />

## 参考文档

- [Response Wrapping — Concepts](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping)
- [Cubbyhole Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole)
- [Cubbyhole Response Wrapping Tutorial](https://developer.hashicorp.com/vault/tutorials/secrets-management/cubbyhole-response-wrapping)
- [Policies — min/max wrapping TTL](https://developer.hashicorp.com/vault/docs/concepts/policies)
