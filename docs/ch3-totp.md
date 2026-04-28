---
order: 312
title: 3.12 TOTP 机密引擎：让 Vault 同时充当验证器与认证器
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.12 TOTP 机密引擎：让 Vault 同时充当验证器与认证器

> **核心结论**：TOTP 机密引擎（`totp/`）让 Vault 接管 [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)
> 定义的"基于时间的一次性密码"工作。它有**两种角色**，必须在 `vault write totp/keys/<name> generate=...`
> 时就**明确选择**，二选一不可同时：
>
> - **`generate=true`（Generator 角色）**：Vault 是**认证器**——像 Google Authenticator 一样，
>   持有 secret 并按 30 秒生成一次性 6 位码，外界系统拿这个码去登录。
> - **`generate=false`（Provider 角色）**：Vault 是**验证器**——用户/外界系统持 secret 并生成码，
>   Vault 校验"用户输入的这个码是不是正确的"。
>
> 一图记住：**Vault 自己生码 → Generator；Vault 帮你校码 → Provider。**

参考：
- [TOTP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/totp)
- [TOTP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/totp)
- [RFC 6238 — TOTP: Time-Based One-Time Password Algorithm](https://datatracker.ietf.org/doc/html/rfc6238)
- [RFC 4226 — HOTP](https://datatracker.ietf.org/doc/html/rfc4226)（TOTP 的底层算法）

---

## 1. RFC 6238 三十秒回顾

TOTP 是 HOTP（基于计数器）的"以时间作计数器"变种。算法：

```
T = floor((now - T0) / X)        # 默认 T0 = Unix epoch, X = 30s
HOTP(K, T) = Truncate(HMAC-SHA1(K, T))   # 6 位数字
```

每个对 `(secret K, period X)` 在每个时间窗口里 **全世界产生同一个 6 位码**——
这就是为什么"两端只要时钟对得上 + 共享同一个 secret"就能互相验证。

衍生关键术语：

| 术语 | 含义 |
| --- | --- |
| **`secret` / `key`** | base32 编码的共享密钥（一般 16 ~ 32 字节） |
| **`period`** | 每个码的有效时间窗口，默认 30s |
| **`digits`** | 码的长度，默认 6（也支持 8） |
| **`algorithm`** | HMAC 算法，默认 SHA1（也支持 SHA256/SHA512） |
| **`issuer`** | 在认证 App 里显示的服务名（如 "GitHub"） |
| **`account_name`** | 在认证 App 里显示的账号（如 "alice@example.com"） |
| **`url`** | 完整的 `otpauth://totp/...` URL，可被生成 QR 码扫码导入 |

`otpauth://` URL 的形状：

```
otpauth://totp/<Issuer>:<Account>?secret=<base32>&issuer=<Issuer>&algorithm=SHA1&digits=6&period=30
```

只要**任意一个**支持 RFC 6238 的客户端（Google Authenticator / Authy / 1Password / `oathtool`）
扫描这个 URL，就能从 Vault 接管认证器角色。

---

## 2. 两种角色的形状对比

![totp-two-modes](/images/ch3-totp/totp-two-modes.png)

| 维度 | Generator (`generate=true`) | Provider (`generate=false`) |
| --- | --- | --- |
| Vault 持有 secret | ✅ 自己生成 / 接管 | ✅ 由调用者写入（含 secret 或 url） |
| Vault 现在能做什么 | `vault read totp/code/<name>` 当前 6 位码 | `vault write totp/code/<name> code=...` 校验 |
| 谁是"展示码"的一方 | Vault | 外部 Authenticator App / 用户 |
| 谁是"校验码"的一方 | 外部登录系统 | Vault |
| 典型用途 | 让 Vault 替代 Google Authenticator 持有 MFA 种子 | 给自家 Web 站添加"扫 Authenticator 二维码 → 登录时校验"功能 |
| 是否能扫 QR 码 | ✅ 创建时 Vault 返回 base64 PNG（可保存为图片） | 取决于 Authenticator App，与 Vault 无关 |

> **二选一是设计决定**：同一个 key 不能既能让 Vault 生码又能让 Vault 校码；
> 想要"我自己也保留 backup secret + 让 Vault 校码"，那就用 Provider 模式，secret 在外部生成后写入 Vault。

---

## 3. Generator 模式：让 Vault 替你拿 Authenticator 种子

```bash
vault secrets enable totp

vault write totp/keys/my-bank \
  generate=true \
  issuer="MyBank" \
  account_name="alice@example.com" \
  exported=true \
  qr_size=200
```

返回字段：

| 字段 | 说明 |
| --- | --- |
| `barcode` | base64 PNG，**可解码后保存为 .png 直接展示给人扫** |
| `url` | `otpauth://totp/MyBank:alice@example.com?secret=...` 完整字符串 |

之后 Vault 可以随时被问"现在的码是多少"：

```bash
vault read totp/code/my-bank
# code  654321
```

外部登录系统（如某个老旧的 SSH bastion）配置上同一个 secret，
登录时：人去 `vault read totp/code/my-bank` → 拿码 → 输给 SSH bastion 校验 → 通过。

> **`exported=true` 与 `exported=false` 的差别**：
> - `true`（默认）：返回 `barcode` + `url`（含 secret），允许"既存在 Vault，又导入到手机 App"
> - `false`：**不返回 url 和 barcode**，secret 完全锁在 Vault 内，连 root 都看不到。
>   选择 `false` 等于宣告"这个 MFA 种子只能 Vault 用，永不能再由别处生码"。
>
> `exported` **只能在创建时生效一次**——之后无论 root 还是任何 policy 都无法再读出 secret。

---

## 4. Provider 模式：让 Vault 替你做"码校验后端"

```bash
# 路径 1：用户已有 otpauth:// URL（可能是别处生成、或扫码所得）
vault write totp/keys/web-2fa-bob \
  generate=false \
  url="otpauth://totp/MyApp:bob@example.com?secret=JBSWY3DPEHPK3PXP&issuer=MyApp&algorithm=SHA1&digits=6&period=30"

# 路径 2：直接传 secret（base32）
vault write totp/keys/web-2fa-bob \
  generate=false \
  key="JBSWY3DPEHPK3PXP" \
  issuer="MyApp" \
  account_name="bob@example.com" \
  algorithm="SHA1" digits=6 period=30
```

校验：

```bash
vault write totp/code/web-2fa-bob code=432198
# Key      Value
# valid    true
```

应用流程：

```
用户登录 → 输入 username/password
        → 输入 Authenticator App 显示的 6 位码
        → 应用调 vault write totp/code/<userKey> code=...
        → 通过则放行
```

**Vault 自动处理时钟漂移**：默认接受**当前 ± 1 个 period** 内的码（`skew=1`），
即 ±30 秒。如设备时钟差较大可在创建时调 `skew` 或 `period`。

---

## 5. 共享字段一览

无论哪种模式，TOTP key 都支持以下字段（均可在 `vault write totp/keys/<name>` 时设置）：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `algorithm` | `SHA1` | HMAC 算法（SHA1/SHA256/SHA512） |
| `digits` | `6` | 码长度（6/8） |
| `period` | `30` | 时间窗口秒数 |
| `skew` | `1` | 校验时容忍的窗口数（仅 Provider 模式生效，Generator 输出永远是当前窗口） |
| `key_size` | `20` | 生成密钥时的字节数（仅 `generate=true`） |
| `issuer` / `account_name` | (空) | 写入 `otpauth://` URL 用 |
| `qr_size` | `200` | barcode PNG 像素（0 表示不生成） |
| `exported` | `true` | 见 §3 |

---

## 6. 删除与替换

```bash
vault delete totp/keys/<name>
```

**删除即销毁** —— 如果是 `exported=false` 的 Generator key，删了就再也回不来了。
没有任何"备份"或"导出"路径。

要轮换 secret？没有原地 rotate 接口，标准做法：

1. 创建新 key（同账号，新 issuer 或带后缀的 name）
2. 让用户重新扫码导入到 Authenticator
3. 一段过渡期后删除旧 key

---

## 7. 路径与权限快速查阅

| 操作 | 路径 | Policy 示例 |
| --- | --- | --- |
| 启用 / 禁用 | `sys/mounts/totp` | `["create","read","update","delete"]` |
| 创建 / 删除 key | `totp/keys/<name>` | `["create","read","update","delete","list"]` |
| 列出所有 key | `totp/keys/` | `["list"]` |
| 读当前码 (Generator) | `totp/code/<name>` (READ) | `["read"]` |
| 校验码 (Provider) | `totp/code/<name>` (UPDATE/WRITE) | `["update"]` |

> **注意**：`totp/code/<name>` 的 READ 与 WRITE 是**两种完全不同的语义**！
> READ = "现在的码是多少"（仅对 Generator key 生效）；
> WRITE/UPDATE = "我提交一个码请校验"（仅对 Provider key 生效）。
> 写 Policy 时要按角色精准给权限——不要为 Provider key 开 `read` 权限（那是无意义的）。

---

## 8. 与其它章节的关系

```
[2.5 Auth Methods]      ← TOTP 不是认证方法本身，但常用于增强其它认证（MFA Step-up）
[2.6 Policies]          ← 用 Policy 区分 Generator-only 与 Provider-only 角色
[3.1 Secrets Engines]   ← 引擎通用框架
[3.12 TOTP] ◄── 你在这儿
[未来 ENT MFA]          ← Vault Enterprise 的内置 MFA 体系会用 TOTP 引擎做后端
```

---

## 9. 三个最容易踩的坑

1. **`exported=false` 的 Generator key 一旦丢了 Vault 数据就永远找不回** —— 它本质等同于 Authenticator App 里那个种子，
   除了删了重建（用户重扫码）没有其它恢复方法。涉及金融/支付 MFA 时务必先确认备份方案。

2. **Provider 模式给 Policy 的常见错误：开 `read` 不开 `update`** —— `vault write totp/code/...`
   实际是 update 操作；只开 read 会得到 403。

3. **服务器与 Authenticator App 时钟必须基本同步** —— `skew=1` 给了 ±30s 容忍，但若服务器漂移到 1 分钟以上，
   所有码都会被 Vault 判定无效。生产环境务必确保 NTP 健康。

---

## 参考文献

- [TOTP Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/totp)
- [TOTP Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/totp)
- [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)、[RFC 4226](https://datatracker.ietf.org/doc/html/rfc4226)
- [Key Uri Format (otpauth://)](https://github.com/google/google-authenticator/wiki/Key-Uri-Format)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-totp"/>
