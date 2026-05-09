---
order: 312
title: 3.12 TOTP 机密引擎：让 Vault 同时充当生成器与校验端
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.12 TOTP 机密引擎：让 Vault 同时充当生成器与校验端

> **核心结论**：TOTP 的本质是“服务器端”和“客户端认证器”各自保存同一个 secret，再用当前时间和同一套算法算出 6 位或 8 位数字。
> 登录时客户端提交这个数字，服务器端用自己保存的 secret 和当前时间再算一遍；数字对得上，就说明对方确实拥有同一个 secret。
> Vault 的 TOTP 机密引擎就是这套机制的一种实现：作为 **generator** 时，它像 Google Authenticator 一样生成 TOTP code；作为 **provider** 时，它像 Google.com 登录服务一样生成 secret 并校验第三方 App 产生的 TOTP code。

参考：
- [TOTP secrets engine](https://developer.hashicorp.com/vault/docs/secrets/totp)

![totp-two-modes](/images/ch3-totp/totp-two-modes.png)


---

## 1. 先用一句话理解 TOTP

TOTP 可以先不用想成“魔法验证码”，而是想成一个很简单的共享秘密校验：

```text
同一个 secret + 当前时间 + 同一套算法 = 当前这一刻的 6 位或 8 位数字
```

注册 TOTP 时，服务器端保存一份 secret，用户手机里的 Microsoft Authenticator、Google Authenticator、1Password，或者 Vault 这一类工具也保存同一份 secret。
之后登录时，客户端认证器不会把 secret 发给服务器，而是用 secret 和当前时间算出一个短数字。
服务器端也用自己保存的 secret 和当前时间算一遍；如果两边数字一致，就说明提交 code 的人至少拥有这份 secret。

所以 TOTP 校验的关键不是“这个数字本身有多神秘”，而是：**只有拿到同一个 secret 的一方，才能在同一个时间窗口里算出同一个数字**。
常见配置是每 30 秒换一次 6 位数字，也可以配置成 8 位、10 秒窗口、SHA256 等其它参数；只要 secret、时间窗口、位数和算法一致，不同认证器算出来的结果就应该一致。

Vault 的 TOTP secrets engine 就是在这套标准机制上提供两个角色：它既可以保存已有 secret 并生成 code，也可以自己生成 secret 并验证用户提交的 code。
官方文档把这两个能力拆成两种身份：generator 与 provider。

| 身份 | Vault 在做什么 | 官方类比 |
| :--- | :--- | :--- |
| generator | Vault 根据已经配置好的 named key 生成新的 time-based OTP code。 | Google Authenticator |
| provider | Vault 生成新的 key，并验证使用这些 key 生成的 passwords。 | Google.com sign in service |

这张表的关键不是“哪个更安全”，而是“谁持有种子、谁验证口令”：generator 模式下，Vault 读取 `/code` 端点来输出 code；provider 模式下，Vault 接收用户提交的 code 并返回 `valid` 结果。

---

## 2. Generator 模式：用 Vault 代替传统 TOTP 生成器

Generator 模式下，TOTP secrets engine 可以作为 TOTP code generator 使用。
在这种模式中，它可以替代 Google Authenticator 这一类传统 TOTP generator。
官方文档给出的安全收益是：生成 code 的能力受 policy 保护，并且整个过程会被审计。

### 2.1 设置步骤

多数 secrets engines 在执行功能之前都必须先完成配置，这些步骤通常由 operator 或 configuration management tool 完成。

第一步是启用 TOTP secrets engine。

```bash
vault secrets enable totp
```

默认情况下，secrets engine 会挂载到与引擎名称相同的路径，也就是 `totp/`。
如果要把它启用到不同路径，可以使用 `-path` 参数。

第二步是配置一个 named key，key 的名字会作为说明用途的人类可读标识。

```bash
vault write totp/keys/my-key \
	url="otpauth://totp/Vault:test@test.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault"
```

这里的 `url` 对应第三方服务提供的条形码里的 secret key 或 value。

### 2.2 生成 code

当 secrets engine 已经配置好，并且 user 或 machine 拥有带有合适权限的 Vault token 后，它就可以生成 credentials。

生成新的 time-based OTP 时，需要用 key 的名字读取 `/code` endpoint。

```bash
vault read totp/code/my-key
```

官方示例的返回值中包含 `code` 字段。

```text
Key     Value
---     -----
code    260610
```

ACL 可以把 TOTP secrets engine 的使用限制成：受信任的 operators 管理 key definitions，而 users 与 applications 只能读取它们被允许读取的 credentials。

---

## 3. Provider 模式：让 Vault 生成 key 并验证用户 code

Provider 模式下，TOTP secrets engine 可以生成新的 keys，并验证使用这些 keys 生成的 passwords。
官方文档把这种模式类比为 Google.com sign in service。

### 3.1 设置步骤

Provider 模式同样需要在执行功能之前先完成 secrets engine 配置，这些步骤通常由 operator 或 configuration management tool 完成。

第一步同样是启用 TOTP secrets engine。

```bash
vault secrets enable totp
```

默认挂载路径仍然是引擎名称对应的 `totp/`，需要其他路径时仍然使用 `-path` 参数。

第二步是创建一个 named key，并使用 `generate` option 告诉 Vault 充当 provider。

```bash
vault write totp/keys/my-user \
	generate=true \
	issuer=Vault \
	account_name=user@test.com
```

官方示例的响应包含 `barcode` 与 `url` 两类输出。
`barcode` 是 base64-encoded barcode，`url` 是 OTP url。
这两者是等价的，并且都应该交给需要用 TOTP 进行认证的用户。

```text
Key        Value
---        -----
barcode    iVBORw0KGgoAAAANSUhEUgAAAMgAAADIEAAAAADYoy0BA...
url        otpauth://totp/Vault:user@test.com?algorithm=SHA1&digits=6&issuer=Vault&period=30&secret=V7MBSK324I7KF6KVW34NDFH2GYHIF6JY
```

### 3.2 验证 code

在 provider 模式的使用阶段，用户提交由第三方 App 生成的 TOTP code 给 Vault 验证。

```bash
vault write totp/code/my-user code=886531
```

官方示例的验证响应返回 `valid=true`。

```text
Key      Value
---      -----
valid    true
```

---

## 4. 两种模式的端点心智模型

Generator 模式读取 `totp/code/<key-name>` 来生成新的 time-based OTP。
Provider 模式写入 `totp/code/<key-name>` 并携带 `code` 参数来验证第三方 App 生成的 TOTP code。

| 动作 | CLI 形态 | 结果 |
| :--- | :--- | :--- |
| 生成 code | `vault read totp/code/my-key` | 返回 `code` 字段。 |
| 验证 code | `vault write totp/code/my-user code=886531` | 返回 `valid` 字段。 |

这个差异也解释了 generator 与 provider 的角色边界：一个是 Vault 输出 code，另一个是 Vault 检查 code 是否有效。

---

## 5. 权限边界：把“管理 key”和“读取凭据”拆开

官方文档明确指出，可以用 ACL 限制 TOTP secrets engine 的使用。
一种官方描述的权限分工是：trusted operators 管理 key definitions，users 与 applications 被限制在它们被允许读取的 credentials 范围内。

因此，在 generator 模式中，`totp/keys/...` 更接近 key definition 管理面，而 `totp/code/...` 更接近 credential 读取面。
在 provider 模式中，`totp/keys/...` 用于创建 named key，`totp/code/...` 用于验证用户提交的 code。

---

## 6. 本章实验要验证的最小闭环

本章的互动实验围绕官方文档中的两个最小闭环展开：generator 闭环与 provider 闭环。

Generator 闭环包含三步：启用 `totp` 引擎、写入带 `url` 的 named key、读取 `/code` endpoint 生成 code。

Provider 闭环包含三步：启用 `totp` 引擎、用 `generate=true` 创建 named key、向 `/code` endpoint 写入用户 code 并读取 `valid` 结果。

如果只记一条路径，可以先记 generator：`totp/keys/<name>` 保存第三方服务给出的 `otpauth://...` URL，`totp/code/<name>` 输出当前 TOTP code。

如果要记 provider，可以记住 `generate=true` 会让 Vault 成为 provider，并且响应里的 barcode 与 OTP url 都可以交给使用 TOTP 认证的用户。

---

## 7. API 入口

TOTP secrets engine 提供完整的 HTTP API。
官方 TOTP 页面把更细的 HTTP API 细节指向 “TOTP secrets engine API”。

下面给出与第 2、3 节 CLI 等价的最小 `curl` 形态，方便在脚本 / 微服务里直接调用。所有请求都需要带 `X-Vault-Token` header；写入类操作走 `POST`，读取走 `GET`。

```bash
# 启用 TOTP 引擎（等价：vault secrets enable totp）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"type":"totp"}' \
  $VAULT_ADDR/v1/sys/mounts/totp

# Generator 模式：写入带 otpauth URL 的 key（等价：vault write totp/keys/my-key url=...）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"url":"otpauth://totp/Vault:test@test.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault"}' \
  $VAULT_ADDR/v1/totp/keys/my-key

# Generator 模式：读取当前 code（等价：vault read totp/code/my-key）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/totp/code/my-key

# Provider 模式：让 Vault 生成 key（等价：vault write totp/keys/my-user generate=true ...）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"generate":true,"issuer":"Vault","account_name":"user@test.com"}' \
  $VAULT_ADDR/v1/totp/keys/my-user

# Provider 模式：验证用户提交的 code（等价：vault write totp/code/my-user code=886531）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"code":"886531"}' \
  $VAULT_ADDR/v1/totp/code/my-user

# 清理：删除 key（等价：vault delete totp/keys/my-key）
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request DELETE \
  $VAULT_ADDR/v1/totp/keys/my-key
```

注意 generator 与 provider 共用 `totp/code/<name>` 这一条路径——区别只在于 HTTP 方法：generator 用 `GET` 输出 code，provider 用 `POST` 携带 `code` 字段做校验。

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-totp"/>
