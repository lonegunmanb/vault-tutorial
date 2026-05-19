---
order: 100
title: 9.9 把 Vault 当成网站的 LDAP + TOTP 登录网关：两阶段登录与首次绑定
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.9 把 Vault 当成网站的 LDAP + TOTP 登录网关：两阶段登录与首次绑定

> **核心结论**：自 Vault 1.10 引入 **Login MFA** 之后，"用户名 + 密码 + 动态验证码"这种最常见的网站登录方式，可以**整段下沉到 Vault**——网站既不需要自行连接 LDAP，也不需要自行生成或校验 TOTP，只需按 Vault 规定的"两阶段登录"协议与之交互即可：第一阶段把用户输入的 LDAP 账号密码提交给 Vault，Vault 返回一个尚未完成认证的 `mfa_request_id`；第二阶段网站把用户在 Authenticator App 中看到的 6 位数字连同该 id 再次提交给 Vault，换取一份正式的 Vault Client Token，登录即告完成。本节用一个尽量精简的 Go 网站把该流程完整演示一遍，并正面解决"新用户首次登录尚未绑定 TOTP"这一鸡生蛋问题。

参考：

- [Login MFA — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/auth-methods/multi-factor-authentication)
- [Login MFA — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/login-mfa)
- [Login MFA Validate API — `/sys/mfa/validate`](https://developer.hashicorp.com/vault/api-docs/system/mfa/validate)
- [Login Enforcement API — `/sys/mfa/login-enforcement`](https://developer.hashicorp.com/vault/api-docs/system/mfa/login-enforcement)
- [TOTP MFA Method API — `/sys/mfa/method/totp`](https://developer.hashicorp.com/vault/api-docs/system/mfa/totp)
- 已学衔接：[2.5 身份实体（Identity Entity）](/ch2-identity-entity)、[4.7 LDAP 认证方法](/ch4-ldap)、[9.5 OpenLDAP 口令轮转](/ch9-ldap-rotation)（OpenLDAP 容器与 alice 用户在两节里复用）

---

## 1. 我们想要的网站登录流程，画到纸上

先把目标画出来——读完整节、合上文档，你应该能凭印象画出这张图：

```
浏览器                网站后端 (Go)                Vault                  OpenLDAP
  │  用户名+密码  →    │                            │                       │
  │                    │  POST /v1/auth/ldap/login/alice  (含 password)  → │
  │                    │                            │  ── bind alice ──→    │
  │                    │                            │  ←── 绑定成功 ────    │
  │                    │  ← 200 {auth.mfa_requirement.mfa_request_id, ...} │
  │  ← 渲染"请输入  ←  │                                                     │
  │     6 位验证码"    │                                                     │
  │                    │                                                     │
  │  6 位 OTP    →    │                                                     │
  │                    │  POST /v1/sys/mfa/validate                          │
  │                    │     {mfa_request_id, mfa_payload}        →          │
  │                    │  ← 200 {auth.client_token = "hvs.xxx", ...}        │
  │  ← Set-Cookie   ←  │  (网站把 Vault Token 当作"登录已完成"的凭证          │
  │     "你登录成功"   │   保存到自家 Session 里，浏览器只看到网站自己的       │
  │                    │   Session Cookie，并不直接接触 Vault Token)         │
```

这张图里有三个容易被忽视的关键点：

1. **网站后端从头到尾不直接连接 LDAP，也不自行计算 TOTP**。所有验证均为网站 → Vault → (LDAP)，Vault 是"代办登录的中间人"。
2. **第一阶段的 HTTP 响应中没有 `client_token`**——只有一个 `mfa_request_id`。这正是 Login MFA 协议的精髓：登录被拆成两步，第一步只确认"密码正确"，第二步才颁发 Token。
3. **`mfa_request_id` 必须在同一份 HTTP 流程中尽快使用**——其有效期很短（默认 5 分钟）且**一次性**，浏览器刷新或切换标签页即作废，因此网站必须将其保存在服务端 Session 中，并与当前浏览器的 Cookie 绑定。

记住这三点之后，后续所有配置与代码都是在为这张图打基础。

---

## 2. 为什么把这些事下沉到 Vault 是划算的

如果不下沉到 Vault，一个最朴素的"LDAP + TOTP"网站至少要自己背三件事：

| 自己写 | 要担心的事 |
| --- | --- |
| LDAP simple bind | 连接池、TLS、`userPassword` 散列算法、密码错次数锁定、目录拓扑变更 |
| TOTP 密钥的生成与存储 | 每个用户一份共享密钥怎么落库、用什么算法加密、怎么轮换、丢了怎么补 |
| 时间窗口与防重放 | RFC 6238 的 30 秒步长、允许的前后偏移、同一 OTP 不能被重复用 |

把这三件事交给 Vault 后，网站后端剩下的工作只有两次 HTTP 调用——本节末尾的 Go 实现整个核心逻辑不足 150 行。Vault 这一侧的"配置成本"也很低：一次性执行四条 `vault write` 命令即可。

更现实的好处是**审计**——所有登录尝试、所有 MFA 校验、所有 Token 颁发都会在 Vault 的 audit device 中留下一条结构化的 JSON 记录，第 8 章讲过的取证方法可以原封不动地复用。

---

## 3. Vault 这一侧要装好的四块积木

按"从下往上"的依赖顺序：

### 3.1 LDAP 认证方法（auth/ldap）

把 OpenLDAP 接进来。注意 `userdn` 与 `groupdn` 决定 Vault 去哪一棵子树里找用户：

```bash
vault auth enable ldap
vault write auth/ldap/config \
    url="ldap://openldap.example.com" \
    userdn="ou=users,dc=learn,dc=example" \
    groupdn="ou=groups,dc=learn,dc=example" \
    userattr="cn"
```

这一步之后，Vault 就具备了"拿 LDAP 账号密码做身份校验"的能力——后续所有 `POST /v1/auth/ldap/login/<username>` 调用都会让 Vault 去 OpenLDAP 做一次 simple bind。在还没加上 §3.3 的 enforcement 之前，你可以用 `vault login -method=ldap username=alice` 直接登录验证连通性。

### 3.2 TOTP MFA 方法（sys/mfa/method/totp）

接下来告诉 Vault "我要用 TOTP 这种 MFA 方法"：

```bash
vault write sys/mfa/method/totp/my-totp \
    issuer="MyWebsite" \
    period=30 \
    algorithm=SHA1 \
    digits=6
```

读取该方法时会看到一个 `id` 字段（UUID）——这才是后续所有命令都需要引用的"这一类 MFA 方法的内部句柄"，也就是常说的 method ID，请妥善记录。

> 这里的 `my-totp` 只是为该方法取的易读名称，可任意命名；而 `id` / method ID 由 Vault 自动生成、固定不变，是真正的引用 key。

### 3.3 Login Enforcement（sys/mfa/login-enforcement）

仅定义一种 MFA 方法是不够的——还需要告诉 Vault "**哪些登录流程必须强制经过这一种 MFA**"。这一步通过一个名为 *login enforcement* 的对象表达：

```bash
# 先拿到 LDAP 认证方法的 accessor（每个挂载实例独有的内部 ID）
LDAP_ACC=$(vault auth list -format=json | jq -r '.["ldap/"].accessor')
TOTP_ID=$(vault read -field=id sys/mfa/method/totp/my-totp)

vault write sys/mfa/login-enforcement/ldap-mfa-enforce \
    mfa_method_ids="$TOTP_ID" \
    auth_method_types="ldap" \
    auth_method_accessors="$LDAP_ACC"
```

该命令的语义为："任何**通过 ldap 这一类方法**且**经由 `auth_ldap_xxxxx` 这一具体挂载**发起的登录尝试，都必须额外通过 `my-totp` 校验"。这条规则一旦写入，本节后续所有 `auth/ldap/login/...` 调用都不再直接返回 Token，而是先返回一个 `mfa_requirement`。

### 3.4 用户的 TOTP 密钥（`sys/mfa/method/totp/<name>/admin-generate`）

上述三步是**对整套系统**的配置；这一步是**对单个用户**的配置——为 alice 在 Authenticator App 中绑定一份仅属于她的 TOTP 密钥：

```bash
ALICE_ENTITY_ID=$(vault read -field=id identity/entity/name/alice)

vault write sys/mfa/method/totp/my-totp/admin-generate \
    entity_id="$ALICE_ENTITY_ID"
```

返回中包含两项内容：

- `url`：`otpauth://totp/MyWebsite:alice?secret=XXXX&...`，可直接据此生成二维码供 alice 扫描；
- `barcode`：上一行 URL 渲染而成的 PNG 二维码 Base64。

alice 扫码后，其手机与 Vault 之间即拥有同一份共享密钥，此后每 30 秒生成的 6 位数字均可由 Vault 通过 `mfa/validate` 校验。

> ⚠️ 该 API 名为 *admin-generate*：调用它需持有一份具备操作该 MFA 方法权限的 token。生产环境中通常封装为一个独立的 "enrollment service"，由用户首次登录时触发；本节实验中为简化起见直接使用 root token 演示。

---

## 4. "新用户登录死循环"是怎么回事，又怎么破

仅摆好上述四块积木**仍会出现问题**——而这正是 Login MFA 最经典的初学者陷阱：

> 系统启用强制 MFA 后，任何人登录都必须先通过 TOTP；但用户的 TOTP 密钥又必须先存在 **Identity Entity** 才能生成；而 Identity Entity 通常是在用户**首次登录成功**时由 Vault 顺带创建的。
>
> 于是新用户陷入：登录 → 被要求 MFA → 无 TOTP → 登录失败 → 无 Entity → 无法 `admin-generate` → 永远无法登录。

破解方法很直接：**将"创建 Entity"从"登录的副作用"中剥离出来，改由管理员显式执行一次**。具体顺序如下：

```bash
# (a) 管理员先创建 alice 的 Entity（此步无需 alice 知晓密码）
ALICE_ENTITY_ID=$(vault write -field=id identity/entity name=alice policies=default)

# (b) 将 LDAP 侧的 alice 与该 Entity 绑定为同一身份
vault write identity/entity-alias \
    name=alice \
    canonical_id="$ALICE_ENTITY_ID" \
    mount_accessor="$LDAP_ACC"

# (c) alice 现已具备 Entity，可为其生成 TOTP 密钥
vault write sys/mfa/method/totp/my-totp/admin-generate \
    entity_id="$ALICE_ENTITY_ID"
```

完成上述三步后，alice 即可正常进行两阶段登录。生产环境中通常将这套动作封装为一个 **enrollment endpoint**——用户打开一次性邀请链接，链接背后使用 admin token 执行上述三步，并将二维码 PNG 推送给用户扫描。本节配套实验中使用一段 shell 脚本演示该 enrollment endpoint。

> 反向思考："为何不能让网站在每位新用户登录时自动创建 Entity 并绑定 TOTP？"——技术上可行，但该路径必须**绕过 login enforcement**（否则陷入同一死循环），这意味着网站需持有一份具备操作 entity 与 mfa 方法权限的高权限 token。将这段权限收敛至一个独立的 enrollment service，是将"日常登录 token"与"用户管理 token"两类权限层级分离的标准做法。

---

## 5. 把流程翻译成 HTTP：两阶段登录的请求 / 响应骨架

### 5.1 第一阶段：LDAP simple bind

```http
POST /v1/auth/ldap/login/alice
Content-Type: application/json

{"password": "alice-ldap-password"}
```

**命中 MFA 强制时**的响应（省略了无关字段）：

```json
{
  "request_id": "...",
  "warnings": ["A login request was issued that is subject to MFA validation. ..."],
  "auth": {
    "client_token": "",
    "mfa_requirement": {
      "mfa_request_id": "5f7e...c2",
      "mfa_constraints": {
        "ldap-mfa-enforce": {
          "any": [
            {"id": "<TOTP_ID>", "type": "totp", "uses_passcode": true, "name": "my-totp"}
          ]
        }
      }
    }
  }
}
```

注意 `auth.client_token` 为**空字符串**——这就是"尚未完成认证"的信号。网站后端需要执行：

1. 检查响应中是否包含 `auth.mfa_requirement`；
2. 将 `mfa_request_id` 与当前用户绑定到自身 Session 中（通过 Set-Cookie）；
3. 渲染 OTP 输入页。

若未启用 MFA 强制，`client_token` 将直接是 `hvs.xxxx` 字符串，可跳过第二阶段。

### 5.2 第二阶段：提交 TOTP 验证码

```http
POST /v1/sys/mfa/validate
Content-Type: application/json

{
  "mfa_request_id": "5f7e...c2",
  "mfa_payload": {
    "<TOTP_method_id>": ["123456"]
  }
}
```

该调用**不需要任何 Vault Token**——`mfa_request_id` 本身即为凭证。响应：

```json
{
  "auth": {
    "client_token": "hvs.CAESIJ...xxxx",
    "policies": ["default"],
    "metadata": {"username": "alice"},
    "lease_duration": 2764800,
    "entity_id": "..."
  }
}
```

至此登录即告完成。网站只需做两件事：

1. **切勿将 `hvs.xxxx` 字符串暴露给浏览器**——应保存在服务端 Session 中，浏览器仅可见网站自身的不透明 Cookie；
2. （可选）记录 `entity_id` 与 `policies`，作为后续在网站内部进行授权判断的依据。

> `mfa_payload` 字段的 key 必须使用 **TOTP method 的 UUID**，而非其易读名称 `my-totp`——这是初学者最容易出错之处，写错时 Vault 会返回 `400 invalid mfa_payload`。

---

## 6. 网站后端最小实现的关键代码骨架

完整代码位于配套实验的 `assets/main.go` 中，此处仅摘录流程最关键的两段：

**第一阶段处理器**（省略了错误处理）：

```go
// POST /login
func handleLogin(w http.ResponseWriter, r *http.Request) {
    username := r.FormValue("username")
    password := r.FormValue("password")

    // 调 Vault：用 LDAP simple bind 把用户密码送给 Vault 校验
    resp, _ := vaultPOST("/v1/auth/ldap/login/"+username,
        map[string]string{"password": password}, "")

    auth := resp["auth"].(map[string]any)

    // 分支一：MFA 强制 → 把 mfa_request_id 入 Session、跳 OTP 页
    if mfa, ok := auth["mfa_requirement"].(map[string]any); ok {
        sid := newSession(&session{
            Username:     username,
            MFARequestID: mfa["mfa_request_id"].(string),
        })
        setCookie(w, sid)
        http.Redirect(w, r, "/mfa", http.StatusSeeOther)
        return
    }

    // 分支二：没启 MFA → 直接拿到 Token
    completeLogin(w, username, auth["client_token"].(string))
}
```

**第二阶段处理器**：

```go
// POST /mfa
func handleMFA(w http.ResponseWriter, r *http.Request) {
    sess := loadSession(r) // 从 Cookie 反查
    otp := r.FormValue("otp")

    payload := map[string]any{
        "mfa_request_id": sess.MFARequestID,
        "mfa_payload": map[string][]string{
            totpMethodID: {otp}, // 注意是 UUID，不是 my-totp
        },
    }
    resp, _ := vaultPOST("/v1/sys/mfa/validate", payload, "")

    token := resp["auth"].(map[string]any)["client_token"].(string)
    completeLogin(w, sess.Username, token)
}
```

`completeLogin` 的职责是将 token 写入服务端 session、清除 `MFARequestID`，并跳转至 `/protected`。

---

## 7. 一些容易忽略的工程细节

1. **`mfa_request_id` 是一次性的**：用户在 OTP 页输错验证码后，再次提交时仍使用同一个 `mfa_request_id`——但 Vault 已将其消耗，会返回 `mfa request not found`。**正确做法**：第一阶段失败时让用户重新提交"用户名 + 密码"，**不要**在 OTP 页提供"重新发送"按钮。
2. **不要将 Vault Token 写入 Cookie**：即便附加 `HttpOnly`，浏览器端的扩展或 XSS 仍可能获取；将其保留在服务端 Session、浏览器仅可见 session id，是更稳妥的安全边界。
3. **登出时主动执行 `revoke-self`**：调用 `POST /v1/auth/token/revoke-self`（携带待撤销的 token）让 Vault 立即撤销，而非任其"自然到期"——这可大幅缩短 token 泄漏后的危害窗口。
4. **启用审计设备**：第 8 章介绍的 file audit device 可为**每一次** ldap login 与 mfa validate 提供完整的结构化 JSON 记录，包括是否被拒、命中了哪一条 enforcement——排查"alice 为何无法登录"通常即从此处入手。
5. **rate limit quota**：即 9.1 节介绍的 production hardening——为 `auth/ldap/login` 添加一条速率配额，可阻挡相当一部分密码暴力破解。MFA 强制仅防御"密码正确之后"的环节，并不防御"持续猜测密码"。

---

## 8. 本节小结

- Vault 的 **Login MFA** 将"密码 + 动态验证码"的登录拆分为两次 HTTP 调用，网站只需按协议与之交互，便无需触及任何 LDAP / TOTP 的实现细节；
- Vault 一侧需要四块积木：`auth/ldap`、`sys/mfa/method/totp/<name>`、`sys/mfa/login-enforcement/<name>`、`sys/mfa/method/totp/<name>/admin-generate`，前三者为系统级一次性配置，最后一项为每个用户一次性配置；
- "新用户死循环"的破解办法是：管理员**显式**为用户创建 Entity 与 entity-alias，再通过 `admin-generate` 为其下发 TOTP 密钥；生产环境中应将此段流程封装为 enrollment service；
- 网站后端需要管理的两项凭据分别是：第一阶段获得的 `mfa_request_id`（短期、一次性、Session 内存）与第二阶段获得的 `client_token`（中期、可撤销、服务端 Session）；
- 在两次 HTTP 调用之外，还需配合审计设备与 rate limit quota，方可构成真正可投产的最小集合。

---

## 9. 动手实验

本节配套了一个 Killercoda 实验：在单台主机上启动 OpenLDAP（容器）、dev 模式 Vault，以及一个用 Go 标准库 `net/http` 编写的最小网站（监听 `:8080`）。你将依次完成：① 检查环境与四块积木的预置状态；② 体验"未绑定 TOTP 时的死循环"，并亲自执行一次 enrollment 为 alice 绑定 Authenticator；③ 在终端使用 `curl` 配合 `oathtool` 完整执行一次两阶段登录，再在浏览器中复现同一流程；④ 验证两类负面用例（错误 OTP、已使用的 `mfa_request_id`）确实被 Vault 当场拒绝，并在审计日志中检索整个过程的结构化 JSON 记录。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-ldap-mfa-gateway" title="实验：用 Go 网站演示 Vault LDAP + TOTP 两阶段登录与首次绑定" />
