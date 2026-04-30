# 第三步：Provider 模式——Vault 生 seed，oathtool 模拟用户 app 验证

[3.12 章 §3](/ch3-totp) 讲过：Provider 模式下 Vault 像 Google.com
登录服务一样**自己生成 seed key**，把 barcode 与 `otpauth://...`
URL 发给用户，用户用任何 authenticator app 扫码后产生的 6 位数字
回提到 Vault，Vault 负责说 `valid` / `invalid`。

这一步把这条闭环用 oathtool 在终端里跑通——`oathtool` 在这里**完全
扮演"用户手机上的 authenticator app"的角色**。

## 3.1 generate=true 让 Vault 当 provider

跟 Step 2 关键差异在 `generate=true`——这个 option 告诉 Vault：
"seed 不要从外部来，你自己生一个"。

```bash
vault write -format=json totp/keys/my-user \
    generate=true \
    issuer=Vault \
    account_name=user@test.com \
    > /root/my-user-key.json

jq -r '.data | keys[]' /root/my-user-key.json
```

会看到响应里有两类输出：

```
barcode
url
```

`barcode` 是 base64 编码的 PNG 二维码（给用户拿手机扫的），`url` 是
跟二维码内容**等价**的 `otpauth://...` 链接。两者承载的是**同一个
新生成的 seed**。

> 跟 Step 2 的 generator 模式做对比：那里 `vault read totp/keys/my-key`
> 响应里**没有 url 也没有 secret**——因为 seed 是你从外部喂进去
> 的，Vault 不会再吐回来。这里 provider 模式响应里**有 url（含
> secret）+ barcode**——因为 seed 是 Vault 刚生的，**有且只有这一
> 次机会让你拿走**，不取就再也拿不回来了。

## 3.2 把 barcode 解码出来确认它真是个 PNG

`barcode` 字段是一段很长的 base64 字符串。把它解码存盘：

```bash
jq -r '.data.barcode' /root/my-user-key.json | base64 -d > /root/my-user-qr.png

file /root/my-user-qr.png
ls -l /root/my-user-qr.png
```

`file` 输出应该是 `PNG image data, ...`——确认它是张二维码 PNG。
真实场景里，这张 PNG 会被前端展示给用户，用户用手机里的 Google
Authenticator / Authy / 1Password 扫一下，TOTP 就配置好了。

> 终端里没法扫二维码，但下面 §3.3 我们直接从等价的 `url` 字段里把
> base32 secret 抠出来，绕过"扫码"这一步。

## 3.3 抠出 base32 secret，准备让 oathtool 当"用户手机"

```bash
URL=$(jq -r '.data.url' /root/my-user-key.json)
echo "完整 otpauth url:"
echo "$URL"
```

会看到形如：

```
otpauth://totp/Vault:user@test.com?algorithm=SHA1&digits=6&issuer=Vault&period=30&secret=V7MBSK324I7KF6KVW34NDFH2GYHIF6JY
```

提取其中的 `secret=` 参数：

```bash
SECRET=$(echo "$URL" | grep -oE 'secret=[^&]+' | cut -d= -f2)
echo "用户手机里 authenticator app 拿到的 base32 secret:"
echo "$SECRET"
```

> 真实场景里这一段是用户拿手机扫 §3.2 那张二维码后**手机自己解
> 析出来**的——它从此存在用户手机里那个 app 里，云端再也看不到。
> 我们这里只是用命令行跳过"扫码"这一步。

## 3.4 oathtool 算出"用户手机正显示的 6 位数字"

```bash
CODE=$(oathtool --totp -b "$SECRET")
echo "假装用户手机现在显示的 TOTP code: $CODE"
```

这个 6 位数字就是用户**这一刻**会念给登录界面输入框 / 把它打到
"请输入您的 6 位验证码"那个表单里的东西。

## 3.5 把 code 提交给 Vault 验证（关键的 valid 时刻）

```bash
vault write totp/code/my-user code=$CODE
```

应该看到：

```
Key      Value
---      -----
valid    true
```

这就是 provider 模式的核心闭环——**Vault 把它存在 storage 里那个 seed
拿出来，按当前时间窗口算 TOTP，跟你提交的 code 比对，对得上就返回
`valid=true`**。换句话说，Vault 此刻扮演的就是 google.com 登录服务
那个"我来核对你输入的 6 位数字"的角色。

## 3.6 故意提交一个错误 code，看 valid=false

```bash
vault write totp/code/my-user code=000000
```

会看到：

```
Key      Value
---      -----
valid    false
```

注意它是**正常返回 + valid=false**，**不是报 401 / 403**。这是 TOTP
验证语义的本意——验证失败本身就是合法的业务结果，调用方负责根据
`valid` 字段判断要不要让用户登录。生产里要在这层之上自己叠"几次错
误锁账户"之类的策略。

## 3.7 演示时间 skew 窗口的实际效应

[官方 API 文档](https://developer.hashicorp.com/vault/api-docs/secret/totp#create-key)
里 provider 模式的 `skew` 参数默认是 `1`——意思是**Vault 在验证时
不仅看当前 30s 窗口，还看前后各一个窗口**，总共 3 个窗口都接受。这
是为了对抗用户手机时钟与 Vault 服务器时钟的轻微漂移。

我们做个实验直接看 skew 在干什么：

```bash
# 先记下当前 code
CODE_NOW=$(oathtool --totp -b "$SECRET")
echo "code_now : $CODE_NOW"

# 等 30 多秒，跨过一个窗口
sleep 35

# 此时 Vault 内部已经进入了下一个窗口，但默认 skew=1 仍然接受上一个窗口
vault write totp/code/my-user code=$CODE_NOW
```

应该仍然返回 `valid=true`——因为 `code_now` 落在 Vault 当前窗口
**的前 1 个窗口**里，被 skew=1 放行。

再等 60 多秒（总共已经跨过 3 个窗口），让 `code_now` 彻底过期：

```bash
sleep 65
vault write totp/code/my-user code=$CODE_NOW
```

这次几乎一定 `valid=false`——同一个 code 已经超出 skew 窗口范围。

> 这条实验直观说明：**TOTP code 不是"那一刻才有效"，而是有一个由
> `period × (1 + 2*skew)` 决定的容忍窗口**。默认配置（period=30,
> skew=1）下窗口宽度 ≈ 90 秒。Step 4 我们会演示如何把 `skew` 调成
> `0` 收紧到 30 秒。

## 3.8 一次成功的 code 能不能被重放？

TOTP 标准本身**没有强制规定**"一个 code 只能用一次"——这跟 HOTP
不同。但 Vault 的 provider 模式**自己加了一层防重放**：每个 key
在内部记账"这串数字在当前窗口里已经被用过"，同一 code 第二次提交
会被直接拒绝。

```bash
# 同一个还在窗口里的 code 连提两次
CODE=$(oathtool --totp -b "$SECRET")
vault write totp/code/my-user code=$CODE
vault write totp/code/my-user code=$CODE
```

第一次会返回：

```
Key      Value
---      -----
valid    true
```

第二次直接是 HTTP 400 报错：

```
Error writing data to totp/code/my-user: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/totp/code/my-user
Code: 400. Errors:

* code already used; wait until the next time period
```

注意这里的返回**不再是** `valid=false` 这种业务字段，而是 HTTP 400
这种**协议层错误**——Vault 在算 TOTP 之前就先查"这串数字本窗口用
过没"，命中就直接拒收。和 §3.6 那种"算出来对不上" 的 `valid=false`
是两条完全不同的失败路径。

> 这条防重放是**每个 key 独立**的：换一个 key 的 code、或者等到
> 下一个时间窗口（用 `oathtool --totp -b "$SECRET"` 重新算一遍）
> 就会立刻恢复 `valid=true`。换句话说，Vault 不需要业务层再叠一层
> (user, code, window) 三元组去重——provider 模式的 `/code` 端点
> 已经把"一个 code 只能用一次"这层语义内置好了。

## 3.9 一句话 recap

Provider 模式做的事情和 generator 镜像对称：

```
generate=true       →   Vault 在 storage 里造一个新 seed
                                  │
                                  ├─→  barcode + otpauth url 发给用户（仅此一次）
                                  │
                                  └─→  /code 路径接收用户提交的数字，
                                        按 (period, skew) 窗口比对，
                                        返回 valid=true / false
```

跟 generator 模式的最大对照：

| 维度 | Generator | Provider |
| :--- | :--- | :--- |
| seed 来源 | 第三方喂入 `url=` | Vault `generate=true` 自造 |
| 响应里有 secret/url 吗 | 没有（已落进 storage） | 有，**且只有创建那一次能取到** |
| `/code` 端点的 HTTP 动词 | GET（read）—— Vault 出 code | POST（write code=...）—— Vault 验 code |
| Vault 扮演的角色 | 用户口袋里的 authenticator | google.com 登录服务 |

下一步把 period / digits / algorithm / skew 这些进阶参数过一遍，并
用两条 ACL 把"管 key 的 operator"和"读/验 code 的 user"在权限层面
真正拆开。
