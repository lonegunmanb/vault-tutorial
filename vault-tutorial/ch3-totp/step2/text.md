# 第二步：Generator 模式——喂第三方 url，oathtool 在本机做对照

[3.12 章 §2](/ch3-totp) 讲过：Generator 模式下 Vault 扮演 Google
Authenticator 的角色——第三方服务（GitHub、AWS、各种 SaaS 控制台）
扫码时给你的那段 `otpauth://...`，喂给 Vault 当 named key，之后
`vault read totp/code/<name>` 就持续替你输出当前 TOTP。

这一步的关键不仅是"把官方示例跑通"，而是**用本机 oathtool 用同一
个 base32 secret 独立算一份 TOTP**，证明 Vault 跟硬件 authenticator
完全是同一套 [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)
算法——也就解释了"为什么 Vault 能替代你口袋里的硬件 token"。

## 2.1 把第三方给的 otpauth url 写进 named key

直接用 [官方文档](https://developer.hashicorp.com/vault/docs/secrets/totp#as-a-generator)
的示例 url：

```bash
vault write totp/keys/my-key \
    url="otpauth://totp/Vault:test@test.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault"
```

应该立刻成功 `Success! Data written to: totp/keys/my-key`。

> Generator 模式里 `url` 是必填的——它**就是从第三方服务那里复制
> 过来的 secret key 或 barcode 的内容**。这个 URL 同时编码了 secret
> （base32）、issuer、account、algorithm、digits、period 等所有
> 算 TOTP 需要的参数。

## 2.2 看一下 Vault 解析后的 key 元数据

```bash
vault read totp/keys/my-key
```

会看到类似：

```
Key             Value
---             -----
account_name    test@test.com
algorithm       SHA1
digits          6
issuer          Vault
period          30
```

注意 **`secret` 字段不在响应里**——这跟 SSH CA 私钥一样，seed 一旦
落进 Vault 就只进不出，没有任何 API 能 export。这是设计：seed 泄漏
意味着这台账户的 TOTP 全部失效，所以 Vault 在 API 层堵掉了"读 seed"
这条路。

## 2.3 让 Vault 出第一个 code

```bash
vault read totp/code/my-key
```

会看到：

```
Key     Value
---     -----
code    260610
```

（数字会变——TOTP 每 30 秒一换。）这个 6 位数字就是你**这一刻**的
TOTP；跟你在 Google Authenticator 里看到的那种 6 位数完全等价。

记住这个 code，下一小节我们用 oathtool 在本机独立算一份做对照。

## 2.4 oathtool 在本机用同一个 secret 独立算一份

`oathtool` 是开源的命令行 OATH 工具，能拿一个 base32 secret 直接算
HOTP/TOTP。我们用它把 Vault 当成黑盒，**用一模一样的 secret 在本机
独立算一遍**，看二者是否一致。

先把 secret 抓出来——它就是 §2.1 那条 `otpauth://...?secret=...`
里 `secret=` 之后那一段：

```bash
SECRET="Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G"
echo "base32 secret: $SECRET"
```

oathtool 算一份 TOTP（`-b` 表示 secret 是 base32 编码）：

```bash
oathtool --totp -b "$SECRET"
```

**几乎在同一时刻**让 Vault 也出一份做并排对照：

```bash
echo "oathtool : $(oathtool --totp -b "$SECRET")"
echo "vault    : $(vault read -field=code totp/code/my-key)"
```

两个数字应该**完全一样**。

> 如果你执行得慢、跨过了一个 30 秒边界，就会看到一个差 1 的 code——
> 这不是算错了，而是证明 TOTP "一窗口一变" 的字面意思。重新跑一遍
> 上面那行，两个值通常会重新对齐。

这条对照确认了：**Vault Generator 模式 = 一个把 seed 关进保险柜、
按 RFC 6238 给你出 TOTP 的服务**。它跟硬件 token / Google
Authenticator 的差异**仅仅在于"seed 存哪里 + 怎么调用"**——算法层
一模一样。

## 2.5 等 30 秒看 code 怎么变

`period=30` 意味着 TOTP 窗口每 30 秒滚一次。简单看一下：

```bash
echo "now: $(vault read -field=code totp/code/my-key)"
sleep 31
echo "later: $(vault read -field=code totp/code/my-key)"
```

两个值大概率不同——这就是 "Time-Based" 的字面意义。窗口边界对齐到
**Unix epoch 的整 30 秒倍数**，所以 `sleep 31` 一定能跨过至少一个边
界，必然变化。

## 2.6 把 secret 字段确实读不出来这件事再确认一次

试着用 `-format=json` 看完整响应：

```bash
vault read -format=json totp/keys/my-key | jq .
```

输出里只有 `account_name` / `algorithm` / `digits` / `issuer` /
`period`——**没有 `secret`、没有 `url`、没有任何能让你重建 seed 的
字段**。这一行设计直接决定了 generator 模式的安全收益：seed 一旦
进 Vault 就**只能用、不能复制**。

## 2.7 一句话 recap

Generator 模式做的事情非常窄：

```
第三方 otpauth url   →   Vault 落进 storage（seed 只进不出）
                                  │
                                  └─→  /code 路径按 30s 节拍输出 TOTP
```

下一步走另一头：让 Vault 自己生 seed 当 provider，再让 oathtool 模
拟"用户手机上的 authenticator app"把验证闭环跑通。
