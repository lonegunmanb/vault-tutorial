---
order: 100
title: 9.9 把 Vault OSS 当成网站的 LDAP + TOTP 登录网关：两阶段编排与首次绑定
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.9 把 Vault OSS 当成网站的 LDAP + TOTP 登录网关：两阶段编排与首次绑定

> **核心结论**：Vault Enterprise 的 Login MFA 可以通过 `sys/mfa` 自动把 LDAP 登录拦成“密码阶段 + MFA 阶段”。Vault OSS 调用这些端点会返回 `enterprise-only feature`，所以本节采用 OSS 可跑的方案：网站后端自己编排两阶段登录。第一阶段用 Vault LDAP auth 校验密码并暂存返回的 Vault token；第二阶段用 Vault `totp` secrets engine 校验 OTP，只有 `valid=true` 后才把暂存 token 升级为网站登录态。

参考：

- [LDAP Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/ldap)
- [TOTP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/totp)
- [TOTP Secrets Engine API — `/totp/keys` 与 `/totp/code`](https://developer.hashicorp.com/vault/api-docs/secret/totp)
- [Login MFA — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/login-mfa)（Enterprise 自动拦截方案，本实验用 OSS 手工编排方案替代）
- 已学衔接：[2.5 身份实体（Identity Entity）](/ch2-identity-entity)、[3.13 TOTP 引擎](/ch3-totp)、[4.7 LDAP 认证方法](/ch4-ldap)、[9.5 OpenLDAP 口令轮转](/ch9-ldap-rotation)

---

## 1. 把流程画出来

和 Enterprise Login MFA 最大的差别是：**Vault OSS 在 LDAP 密码正确时会立即返回 token，网站必须自己把它扣住**。

```text
浏览器                网站后端 (Go)                Vault OSS              OpenLDAP
  │  用户名+密码  →    │                            │                       │
  │                    │  POST /v1/auth/ldap/login/alice  (含 password)  → │
  │                    │                            │  ── bind alice ──→    │
  │                    │                            │  ←── 绑定成功 ────    │
  │                    │  ← 200 {auth.client_token = hvs.xxx, ...}         │
  │                    │  token 进入 pending session，暂不算登录完成         │
  │  ← OTP 页面   ←    │                                                     │
  │  6 位 OTP    →    │                                                     │
  │                    │  POST /v1/totp/code/alice  {code:123456}      →    │
  │                    │  ← 200 {data.valid = true}                         │
  │  ← 登录成功   ←    │  pending token 升级为正式 session token             │
```

关键点只有三个：

1. 网站后端不直接连接 LDAP，也不自行实现 TOTP；LDAP 密码校验和 OTP 校验都交给 Vault。
2. 第一阶段拿到的 `client_token` 只说明密码正确，不能马上发给浏览器，也不能马上认为网站登录完成。
3. OTP 错误、流程超时或用户放弃时，网站应该 revoke 掉 pending token，避免“只过了密码阶段”的 token 残留。

---

## 2. Vault 侧要准备什么

### 2.1 LDAP auth

```bash
vault auth enable ldap
vault write auth/ldap/config url=ldap://openldap.example.com userdn=ou=users,dc=learn,dc=example groupdn=ou=groups,dc=learn,dc=example userattr=cn
```

之后网站可以调用 `POST /v1/auth/ldap/login/alice`，让 Vault 去 OpenLDAP 做 simple bind。

### 2.2 TOTP secrets engine

```bash
vault secrets enable totp
```

它的两个核心路径是：

| 路径 | 作用 |
| --- | --- |
| `totp/keys/<name>` | 管理某个用户或账号的 TOTP key 定义 |
| `totp/code/<name>` | provider 模式下写入 `code` 来验证用户提交的 OTP |

本节使用 provider 模式：Vault 生成 alice 的 TOTP seed，并把 `otpauth://...` URL 交给用户绑定 Authenticator。登录时网站把用户输入的 code 交给 Vault 验证。

### 2.3 让 LDAP token 只能验证自己的 TOTP code

网站第二阶段会用第一阶段拿到的 LDAP token 调 `totp/code/alice`。因此 alice 对应的 entity 需要一条很窄的 policy：

```hcl
path "totp/code/alice" {
  capabilities = ["update"]
}
```

然后把 LDAP 侧的 alice 绑定到这个 entity：

```bash
LDAP_ACC=$(vault auth list -format=json | jq -r '.["ldap/"].accessor')
ALICE_ENTITY_ID=$(vault write -field=id identity/entity name=alice policies=default,alice-totp-login)
vault write identity/entity-alias name=alice canonical_id="$ALICE_ENTITY_ID" mount_accessor="$LDAP_ACC"
```

这不是 Enterprise Login Enforcement。它只是在说：“alice 的 LDAP token 可以调用 `totp/code/alice`，但不能管理 `totp/keys/*`。”

---

## 3. 首次绑定：把 TOTP key 交给 alice

首次绑定通常由独立 enrollment service 完成。实验里用 root token 模拟：

```bash
vault write -format=json totp/keys/alice generate=true exported=true issuer=MyWebsite account_name=alice period=30 algorithm=SHA1 digits=6
```

响应里会有：

- `url`：`otpauth://totp/MyWebsite:alice?...&secret=...`，Authenticator App 可以扫码或手动录入；
- `barcode`：同一 URL 的二维码 PNG Base64。

生产里要把“管理 `totp/keys/*`”的权限收敛在 enrollment service 中，不要交给日常登录路径。

---

## 4. HTTP 两阶段骨架

### 4.1 第一阶段：LDAP 密码

```http
POST /v1/auth/ldap/login/alice
Content-Type: application/json

{"password":"alice-ldap-password"}
```

Vault OSS 密码正确时会直接返回 token：

```json
{
  "auth": {
    "client_token": "hvs.xxxx",
    "entity_id": "...",
    "policies": ["default", "alice-totp-login"]
  }
}
```

网站此时只做三件事：把 token 放入服务端 pending session、设置自己的 `sid` Cookie、渲染 OTP 页面。

### 4.2 第二阶段：TOTP code

```http
POST /v1/totp/code/alice
X-Vault-Token: hvs.xxxx
Content-Type: application/json

{"code":"123456"}
```

响应：

```json
{
  "data": {
    "valid": true
  }
}
```

`valid=true` 后，网站才把 pending token 标记为正式 session token。若返回 `valid=false` 或报错，网站撤销 pending token，并让用户回到登录页重新开始。

---

## 5. 网站后端最小状态机

完整代码位于配套实验的 `assets/main.go`。核心逻辑可以压缩成这个状态机：

```go
// POST /login
token := vaultLDAPLogin(username, password)
session.PendingToken = token
redirect("/mfa")

// POST /mfa
valid := vaultValidateTOTP(username, otp, session.PendingToken)
if valid {
    session.Token = session.PendingToken
    session.PendingToken = ""
    redirect("/protected")
} else {
    revoke(session.PendingToken)
    destroySession()
    redirect("/")
}
```

浏览器永远只看到网站自己的 `sid` Cookie；Vault token 不进入浏览器 Cookie 或前端 JavaScript。

---

## 6. 工程细节

1. **pending token 要短 TTL**：实验用内存 session 演示，生产里应放 Redis / 数据库，并设置 5 分钟左右的 pending 过期时间。
2. **OTP 失败要 revoke pending token**：否则攻击者只要通过密码阶段，就会留下一个还活着的 Vault token。
3. **TOTP code 有防重放**：Vault provider 模式下，同一时间窗口内同一个 code 第二次提交会返回 `code already used; wait until the next time period`。
4. **不要把 enrollment 权限给登录路径**：`totp/keys/*` 是管理面，`totp/code/*` 是验证面，两者应拆成不同 policy。
5. **审计设备仍然有价值**：`auth/ldap/login`、`totp/code/alice`、`auth/token/revoke-self` 都会进 audit log。
6. **Enterprise Login MFA 的边界要说清楚**：如果有 Enterprise，可以用 `sys/mfa/login-enforcement` 让 Vault 自动拦截登录；OSS 场景则由网站后端完成这段编排。

---

## 7. 本节小结

- Vault OSS 不能用 `sys/mfa` 自动强制 Login MFA，但可以用 `auth/ldap` + `totp` secrets engine 组合出网站级两阶段登录。
- 第一阶段 token 是 pending token，不等于网站登录完成；第二阶段 `totp/code/alice` 返回 `valid=true` 后才升级 session。
- enrollment 负责写 `totp/keys/alice`，日常登录只需要 `totp/code/alice` 的 `update` 权限。
- 浏览器不直接接触 Vault token；登出、OTP 失败、pending 超时都应 revoke token。
- audit device 和 rate limit quota 仍然是生产化登录防线的一部分。

---

## 8. 动手实验

本节配套了一个 Killercoda 实验：在单台主机上启动 OpenLDAP、dev 模式 Vault、`totp` secrets engine，以及一个用 Go 标准库 `net/http` 编写的最小网站（监听 `:8080`）。你将依次完成：① 检查 LDAP、TOTP 引擎、identity policy 与 alice 尚未绑定 TOTP 的状态；② 体验“密码已通过但 TOTP key 不存在”的 pending 失败，并亲自执行 enrollment；③ 用 `curl` 和浏览器各跑一遍两阶段登录；④ 验证错误 OTP、重放 OTP 与审计日志。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-ldap-mfa-gateway" title="实验：用 Go 网站演示 Vault OSS LDAP + TOTP 两阶段登录与首次绑定" />