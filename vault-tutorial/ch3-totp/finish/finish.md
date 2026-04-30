# 恭喜完成 TOTP 实验！🎉

这一节你把 Vault TOTP 引擎的两条官方路径完整跑了一遍——**全程在终
端里完成**，用 `oathtool` 当作"用户手机上的 authenticator app"，
不需要任何手机或外部服务。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **两个核心端点** | `totp/keys/...` 是 key 定义管理面，`totp/code/...` 是凭据出/验面；二者完全可以单独授权 |
| **Generator** | 第三方喂入的 `otpauth://...` 落进 storage 后 `secret` 字段彻底不可读——seed 只进不出 |
| **算法等价** | `oathtool --totp -b $SECRET` 与 `vault read totp/code/<name>` 输出**完全一致**——TOTP 是开放标准 RFC 6238，Vault 没做任何私有变体 |
| **Provider** | `generate=true` 让 Vault 自造 seed；`url` + `barcode` **只在创建那一次返回**，错过再也拿不回 |
| **valid 语义** | 验证失败是 `valid=false` 这个**业务字段**，不是 HTTP 401/403——上层负责"几次错误锁账户"之类的策略 |
| **skew 窗口** | 默认 `skew=1` 容忍 ~90 秒漂移；`skew=0` 收紧到 30 秒 |
| **防重放** | Vault provider 模式**内置防重放**——同一 code 在同一窗口里第二次提交直接 HTTP 400 `code already used; wait until the next time period`，业务层不需要再叠 (user, code, window) 去重 |
| **period 一致性** | 双方 period 必须一致——`oathtool --time-step-size=10` 对应 Vault `period=10`，不一致就永远算不到一起 |
| **ACL 拆分** | `totp/keys/*` 给 operator，`totp/code/*` 给 user，**两个 token 互相越权立刻 403** |
| **删 key 后果** | seed 物理删除，所有已注册用户的 authenticator app 立刻失效——provider 模式下"换 seed"必须双轨过渡 |

## 一张图总结整章

```
              ┌────────────────────────────────────────────┐
              │         Vault TOTP 机密引擎                │
              └─────────────────┬──────────────────────────┘
                                │
                ┌───────────────┴───────────────┐
                │                               │
       Generator (Step 2)              Provider (Step 3)
       url=otpauth://...                generate=true
                │                               │
                │                               │
       seed 来自第三方                  seed 由 Vault 自造
       响应里看不到                     响应只这一次返回 url+barcode
                │                               │
                ▼                               ▼
       totp/code/<name>                  totp/code/<name>
       GET (read)  ── 出 code            POST (write code=...) ── 验 code
                │                               │
                ▼                               ▼
       Vault = 你口袋里的 OTP 设备     Vault = google.com 那个登录服务

                   ─────────────────────────
                          ACL 边界 (Step 4)
                   ─────────────────────────
       totp/keys/*  ───►  operator policy   (管 key)
       totp/code/*  ───►  user policy       (出/验 code)
       两边互不越权 → 即使 token 泄漏也只爆炸半径里的一半
```

## 留个思考题

实验里 §3.7 演示了"同一个 code 等到下一个窗口仍然 valid=true"，
§3.8 演示了"同一窗口里同一 code 第二次提交会被 Vault 直接拒掉
（HTTP 400 `code already used`）"。**Vault 已经把"一个 code 只能用
一次"这层防重放内置进了 provider 模式**——但这并不意味着 TOTP
在网络劫持场景下就安全了。**剩下的攻击窗口是哪种？应该在哪一层
把它堵住？**

> （提示：Vault 的防重放是"先到先得"语义。如果攻击者在中间人位置
> 截到了用户**还没来得及提交**的明文 code，他可以**抢在用户之前**
> 把这个 code 提交给 Vault——这次 `valid=true` 算在攻击者头上，
> 用户随后再提交反而会撞到 `code already used` 的 400。换句话说，
> Vault 内置防重放**只能保证一个 code 最多被消费一次**，不能保证
> **它一定是被合法用户消费的**。生产里堵这个口的标准做法只有一条：
> 让 code 在网络上**永远不出明文**——Vault 必须挂在 TLS 之后，业
> 务前端到 Vault 之间也必须全段 TLS，**才能匹配传统硬件 token 的
> 安全等级**。）

## 接下来去哪儿

回到 [3.12 章正文](/ch3-totp)：§4 那张端点心智模型对照表里的每一格
你刚刚都亲手撞过；§5 那条 ACL 边界你也用两个独立 token 把它落到了字
面 403。

下一节是 [3.13 Transit 引擎](/ch3-transit)——TOTP 是"按时算 6 位
数字"的小机器，Transit 是"任意明文进、密文出"的通用加密 API，两个
合起来基本能覆盖云原生场景里"非数据库类机密 + 短期密码 + 加解密"
的全部需求。
