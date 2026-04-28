---
order: 313
title: 3.13 Transit 机密引擎：加密即服务 (Encryption as a Service)
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.13 Transit 机密引擎：加密即服务 (Encryption as a Service)

> **核心结论**：Transit 机密引擎（`transit/`）颠覆了 Vault 一贯的"我替你存机密"模型，
> 转而提供**纯密码学服务**："**应用持密文，Vault 持钥匙**"——Vault **不存任何业务数据**，
> 只在调用时按命名密钥执行加密 / 解密 / 签名 / 验签 / HMAC / 派生 / 数据密钥（DEK）生成等操作。
> 可以把它理解成 KV 引擎的**分工反转**：KV 是 Vault 替应用存机密，Transit 是应用自己存数据、只让 Vault 替它守钥匙。
> 关键的运维特性是**无中断密钥轮转**：`rotate` 在密钥下增加新版本，旧版本仍能解密老密文，新加密自动用新版本，
> 配合 `rewrap` 可逐步把存量密文升级到新版本。

参考：
- [Transit Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Transit Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/transit)
- 对照：[3.2 KV v2](/ch3-kv-v2)（Vault 替你**存**机密，本节相反）
- 概念基础：[3.1 Secrets Engines](/ch3-secrets-engines)、[2.6 Policies](/ch2-policies)

---

## 1. 心智模型：寄存处 vs 锁匠柜台

![transit-eaas-vs-kv](/images/ch3-transit/transit-eaas-vs-kv.png)

如果“KV / Transit 互为镜像”还是偏抽象，可以直接换成一个更生活化的比喻：

- **KV 像寄存处**：你把行李交给前台保管，之后再回来取。**前台真的持有你的东西。**
- **Transit 像锁匠柜台**：箱子始终在你手里，锁匠只保管钥匙；你把箱子拿来，请他上锁或开锁，他做完就把箱子还给你。**锁匠从不替你保存箱子里的东西。**
- 所以 **KV 的关键词是“存 / 取机密”**，而 **Transit 的关键词是“拿你的数据来做加密 / 解密”**。

| 维度 | KV 引擎 (3.2/3.4) | Transit 引擎 (本章) |
| --- | --- | --- |
| Vault 持有什么 | 业务机密本身 | 加密用的密钥 |
| 应用持有什么 | 路径名 + Vault Token | 密文 + Vault Token |
| 数据流 | App → 读路径 ← Vault 返机密 | App → 送密文 ← Vault 返明文 |
| 业务数据存在哪 | Vault Storage | App 自己的数据库 / 磁盘 |
| 谁解密 | (无加密概念，直接读) | 必须经过 Vault |
| 撤销访问的方法 | 删 Policy / Token | 删 Policy / Token，**或删整把 key**（一刀切让所有密文失效） |

> **EaaS 的精神**：业务系统的数据库可能里里外外都是密文，**离开了 Vault 一字不通**。
> 这把"内行人也读不出"的能力推给所有微服务，无需在每个服务里硬塞密钥管理代码。

---

## 2. 启用与第一把密钥

```bash
vault secrets enable transit
vault write -f transit/keys/order-pii            # 创建一把默认 key (aes256-gcm96)
vault read transit/keys/order-pii                # 看密钥元数据
```

返回的关键字段：

| 字段 | 说明 |
| --- | --- |
| `type` | 算法（默认 `aes256-gcm96`） |
| `keys` | 已存在的版本号映射（首次创建时只有 `1`） |
| `latest_version` | 加密时使用的版本号（初始 = 1） |
| `min_decryption_version` | 解密时允许的最小版本（默认 1，可调） |
| `min_encryption_version` | 加密时允许的最小版本（默认 0=用 latest） |
| `deletion_allowed` | 默认 `false`——**默认整把 key 不能被删**，必须先 `update deletion_allowed=true` |
| `derived` | 是否启用密钥派生（见 §6） |
| `convergent_encryption` | 是否启用收敛加密 |
| `exportable` | 是否允许 `export` 出原始密钥（默认 false） |

> **`deletion_allowed=false` 是双保险**：避免误操作把整个引擎下所有用此 key 加密的密文一次性变废铁。
> 真要删，必须**两步**：先 update 解锁，再 delete。

---

## 3. 加密与解密

Vault 的明文都按 **base64** 在线传：

```bash
# 加密
vault write transit/encrypt/order-pii \
  plaintext=$(echo -n "13800138000" | base64)
# Key            Value
# ciphertext     vault:v1:dGhpc2lzbm90cmVhbGNpcGhlcnRleHQ...

# 解密
vault write transit/decrypt/order-pii \
  ciphertext=vault:v1:dGhpc2lzbm90cmVhbGNpcGhlcnRleHQ...
# plaintext      MTM4MDAxMzgwMDA=     ← base64("13800138000")
echo MTM4MDAxMzgwMDA= | base64 -d
# 13800138000
```

**ciphertext 的形状是 `vault:v<N>:<base64-data>`**：

- `vault:` 命名空间前缀，Vault 用来识别这是它产生的密文
- `v<N>` 加密时使用的密钥版本号（解密时 Vault 自动按这个版本选私钥）
- `<base64-data>` 实际密文 + nonce + 认证标签

> 应用只需要保存这个不透明字符串，无需关心算法、密钥、版本——这些都被 Vault 隐藏在路由后面。

### 3.1 批量接口

```bash
vault write transit/encrypt/order-pii \
  batch_input='[
    {"plaintext": "MTIz"},
    {"plaintext": "NDU2"}
  ]'
```

返回 `batch_results` 数组对应 ciphertext，性能比 N 次单条调用高一个量级。

### 3.2 关联数据 (Context / Associated Data)

可以在加密时传 `context` 字段（仅当 key 是 `derived=true`）或 `associated_data`（GCM 模式认证额外数据）。
这两个机制让"密文 + 关联数据"必须配对成功才能解密——典型场景：把租户 ID 绑进 associated_data，
让 A 租户密文绝不可能被 B 租户的解密路径破解。

---

## 4. 无中断密钥轮转：`rotate` + `rewrap`

```bash
# 给 key 增加一个版本（v2）
vault write -f transit/keys/order-pii/rotate
vault read transit/keys/order-pii
# latest_version: 2
# keys: {"1": <ts>, "2": <ts>}
```

轮转后：

- 新的 `vault write transit/encrypt/order-pii` 自动使用 v2
- 旧的 `vault:v1:...` **仍然能被解密**（v1 还在 `keys` 里）
- 想强制升级现存密文：

```bash
vault write transit/rewrap/order-pii ciphertext=vault:v1:OLD_DATA...
# 返回新的 vault:v2:NEW_DATA...
```

**`rewrap` 不需要明文** —— Vault 内部用 v1 解密、用 v2 重新加密、把结果给你。
应用要做的就是把数据库里所有 `vault:v1:` 字符串替换成新返回的 `vault:v2:` 字符串。

要让旧版本彻底失效：

```bash
vault write transit/keys/order-pii/config min_decryption_version=2
# 此后所有 vault:v1:... 解密都会被拒绝
```

> 这个组合让密钥轮转**完全异步且零中断**：业务无须停机，按背景批处理速度逐步把 v1 密文升级到 v2，
> 做完后 `min_decryption_version=2` 一刀关掉旧版。

---

## 5. 密钥类型矩阵

`type` 字段决定 key 的算法和支持的操作：

| `type` | 算法族 | 加/解密 | 签/验签 | HMAC | 数据密钥 (DEK) | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| `aes128-gcm96` / `aes256-gcm96` | AES-GCM | ✅ | ❌ | ✅ | ✅ | 默认推荐 |
| `chacha20-poly1305` | ChaCha20-Poly1305 | ✅ | ❌ | ✅ | ✅ | 移动 / IoT 友好 |
| `xchacha20-poly1305` | XChaCha20-Poly1305 | ✅ | ❌ | ✅ | ✅ | 192-bit nonce，可承受更高加密次数 |
| `ed25519` | Ed25519 | ❌ | ✅ | ✅ | ❌ | 签名速度极快，仅签验 |
| `ecdsa-p256` / `p384` / `p521` | ECDSA | ❌ | ✅ | ✅ | ❌ | 兼容传统 PKI |
| `rsa-2048` / `3072` / `4096` | RSA | ✅ (OAEP) | ✅ (PSS/PKCS1) | ✅ | ❌ | 兼容性好但慢 |
| `hmac` | HMAC | ❌ | ❌ | ✅ | ❌ | 仅 HMAC 计算 |
| `aes256-cmac` / `aes192-cmac` | AES-CMAC | ❌ | ❌ | ✅ (CMAC) | ❌ | 1.18+ 新增 |

创建非默认类型的 key：

```bash
vault write transit/keys/signing-key type=ed25519
```

---

## 6. 派生密钥 (`derived`) 与收敛加密

普通 key 加密同样的明文每次得到不同密文（因为 nonce 随机）。
两个高级开关让密文行为更可预测：

### 6.1 `derived=true`：每次调用根据 `context` 派生子密钥

```bash
vault write -f transit/keys/multi-tenant derived=true
```

之后加/解密**必须**传 `context`：

```bash
vault write transit/encrypt/multi-tenant \
  plaintext=$(echo -n "secret" | base64) \
  context=$(echo -n "tenant-A" | base64)
```

Vault 用 HMAC-SHA256(master_key, context) 派生出子密钥后才加密。
**不同 `context` → 不同子密钥 → 密文互相不可解**——这就实现了"主密钥分一把、租户隔离"。

### 6.2 `convergent_encryption=true`：相同 (plaintext, context) → 相同密文

```bash
vault write -f transit/keys/searchable derived=true convergent_encryption=true
```

要求同时启用 `derived=true`。开启后，相同的 `(plaintext, context)` 输入永远得到相同密文——
代价是放弃了 nonce 的随机性（攻击者能识别"这是同一个值"），换来"密文上能做相等性查询"。
典型用途：在加密的 PII 字段上做 SQL `WHERE encrypted_phone = ?` 查询。

> ⚠️ 收敛加密**会泄露明文相等性**——电话号码、身份证号这种集合不大、容易被字典爆破的字段不要用。

---

## 7. 数据密钥 (DEK) 模式：信封加密

![transit-dek-envelope](/images/ch3-transit/transit-dek-envelope.png)

加密大文件 / 大对象时，每次都把 GB 级数据送给 Vault 不现实。**信封加密** 解法：

1. **本地随机生成 DEK**（一次性 32 字节对称密钥）
2. **本地用 DEK** 加密大数据（AES-GCM 等）
3. **让 Vault 用 master key 加密 DEK**（这一步只有 32 字节走 Vault）
4. 存：**密文大数据 + 被 Vault 包过的 DEK**
5. 读时：先把 wrapped DEK 给 Vault 解封，再用 DEK 本地解密大数据

Vault 一站式接口：

```bash
# 生成 wrapped DEK + 同时返回明文 DEK 让你立刻用
vault write -f transit/datakey/plaintext/order-pii
# Key            Value
# plaintext      <base64 of 32-byte DEK>     ← 立刻用它本地加密大数据
# ciphertext     vault:v1:wrapped-dek...     ← 跟密文一起存数据库

# 之后只要 wrapped 形式（不含 plaintext，更安全）
vault write -f transit/datakey/wrapped/order-pii
# 只返回 ciphertext，不返回 plaintext —— 仅用于"还原密钥之前的安全准备"

# 解封 wrapped DEK
vault write transit/decrypt/order-pii ciphertext=vault:v1:wrapped-dek...
# 拿到 base64 DEK 后本地解密
```

DEK 模式好处：

- **大数据从不经过 Vault** —— 性能与本地加密相当
- **被 Vault 锁定的 DEK 替代了"密钥分发"问题** —— 想撤销访问？在 Vault 上 `min_decryption_version` 一调即可
- **配合 key rotate** —— 旧 wrapped DEK 仍能用旧版本解，新生成的自动用新版本

---

## 8. 签名 / 验签 / HMAC

### 8.1 签名（仅非对称类型 key）

```bash
vault write transit/keys/signing-key type=ed25519

# 签
vault write transit/sign/signing-key \
  input=$(echo -n "transfer 100 USD to alice" | base64)
# signature  vault:v1:base64sig...

# 验
vault write transit/verify/signing-key \
  input=$(echo -n "transfer 100 USD to alice" | base64) \
  signature=vault:v1:base64sig...
# valid  true
```

### 8.2 HMAC（对称 key 的"签名"）

```bash
vault write transit/hmac/order-pii input=$(echo -n "msg" | base64)
# hmac  vault:v1:hmacresult...

vault write transit/verify/order-pii \
  input=$(echo -n "msg" | base64) \
  hmac=vault:v1:hmacresult...
# valid  true
```

> HMAC 与 Sign 的差别：HMAC 用对称 key（双方都需要 key 才能验），Sign 用私钥（公钥发出去验）。
> 选 ed25519 / ecdsa / rsa 让 Vault 持私钥、签出来的内容用公钥就能验。

### 8.3 导出公钥

非对称 key 的公钥可以无害地泄露：

```bash
vault read transit/keys/signing-key
# keys.<version>.public_key   <PEM 格式公钥>
```

---

## 9. 路径与权限快速查阅

| 操作 | 路径 | Policy |
| --- | --- | --- |
| 启用 / 禁用 | `sys/mounts/transit` | `["create","read","update","delete"]` |
| 创建 / 配置 / 删除 key | `transit/keys/<name>` `transit/keys/<name>/config` | `["create","read","update","delete"]` |
| 加密 / 解密 | `transit/encrypt/<name>` `transit/decrypt/<name>` | `["update"]`（写操作） |
| 轮转 | `transit/keys/<name>/rotate` | `["update"]` |
| Rewrap | `transit/rewrap/<name>` | `["update"]` |
| 数据密钥 | `transit/datakey/{plaintext,wrapped}/<name>` | `["update"]` |
| 签 / 验 / HMAC | `transit/sign/<name>` `transit/verify/<name>` `transit/hmac/<name>` | `["update"]` |

> **典型最小授权**：业务应用只给 `update` on `transit/encrypt/<name>` + `transit/decrypt/<name>`，
> **不给 `create/update` on `transit/keys/<name>`**——应用只能用密钥，无权改/删/换密钥。
> 密钥管理员另一套 Policy 持有创建/轮转/删除权限。

---

## 10. 安全默认与"不要删 key"

Transit 的几条**默认就严**的安全设定：

| 默认 | 含义 | 想改怎么办 |
| --- | --- | --- |
| `deletion_allowed=false` | key 不能被删除 | `vault write transit/keys/<name>/config deletion_allowed=true` 后再删 |
| `exportable=false` | 不能导出原始 key 字节 | 创建时 `exportable=true`（一旦设了，整个生命周期都可导出，无法收回） |
| `allow_plaintext_backup=false` | `transit/backup/<name>` 不能含明文 key | 同上，创建时 `allow_plaintext_backup=true` |

> 强烈建议：除非有明确"key 必须出门"的合规要求，否则保持 `exportable=false` + `allow_plaintext_backup=false`。
> 这才是真正的"应用持密文，Vault 持钥匙——而且钥匙永不离开 Vault"。

---

## 11. 与其它章节的关系

```
[3.2 KV v2]              ← 镜像对照：那是 Vault 替你存机密；这是 Vault 替你守钥匙
[3.4 Cubbyhole]          ← 都不靠"路径权限模型"，但分别为 Token 隔离 / 加密服务
[3.10/3.11 LDAP/K8s]     ← 那些都是"Vault 向外签发短期凭据"，本章是"Vault 提供算力"
[3.12 TOTP]              ← 同样是"密码学即服务"，TOTP 是时间一次性密码，Transit 是通用加解密+签名
[未来 ENT KMSE]          ← Vault Enterprise 的 KMS Engine 把 Transit 模式扩到云 KMS 后端
```

---

## 12. 三个最容易踩的坑

1. **`plaintext` 必须 base64** —— 直接传明文字符串会被当成已编码、解出乱码。
   命令行务必 `$(echo -n "..." | base64)`，自动化里一定要 `--data-binary @-` 之类的姿势避免换行。

2. **删 key 不可逆，且会让所有密文变废铁** —— 默认 `deletion_allowed=false` 是良性保护。
   想撤销访问应改用 `min_decryption_version` 或 Policy 撤销，而非真的删 key。

3. **轮转后忘了 rewrap，旧密文一直走旧版本解** —— 不会出错，但若旧版本被 `min_decryption_version` 关了就突然全失败。
   生产规范是**每次 rotate 后立即排程 rewrap**，再过几个保留周期才 raise `min_decryption_version`。

---

## 参考文献

- [Transit Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Transit Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/transit)
- [Tutorial - Encryption as a Service](https://developer.hashicorp.com/vault/tutorials/encryption-as-a-service/eaas-transit)
- [NIST SP 800-38D — GCM](https://csrc.nist.gov/publications/detail/sp/800-38d/final)、[RFC 8439 — ChaCha20-Poly1305](https://datatracker.ietf.org/doc/html/rfc8439)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-transit"/>
