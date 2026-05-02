---
order: 313
title: 3.13 Transit 机密引擎：加密即服务 (Encryption as a Service)
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.13 Transit 机密引擎：加密即服务 (Encryption as a Service)

> **核心结论**：Transit 机密引擎（`transit/`）颠覆了 Vault 一贯的"我替你存机密"模型，
> 转而提供**纯密码学服务**："**应用持密文，Vault 持钥匙**"——Vault **不存任何业务数据**，
> 只在调用时按命名密钥执行加密 / 解密 / 签名 / 验签 / HMAC / 哈希 / 随机数 / 派生 / 数据密钥（DEK）生成等操作。
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
| 数据流 | App → 读路径 ← Vault 返机密 | 加密：App 送明文 → Vault 返密文；解密：App 送密文 → Vault 返明文 |
| 业务数据存在哪 | Vault Storage | App 自己的数据库 / 磁盘 |
| 谁解密 | (无加密概念，直接读) | 必须经过 Vault |
| 撤销访问的方法 | 删 Policy / Token | 删 Policy / Token；按版本淘汰可调 `min_decryption_version`；删整把 key 会让所有密文失效 |

> **EaaS 的精神**：业务系统的数据库可能里里外外都是密文，**离开了 Vault 一个字都看不懂**。
> 这把"内行人也读不出"的能力推给所有微服务，无需在每个服务里硬塞密钥管理代码。

---

## 2. 启用与第一把密钥

```bash
vault secrets enable transit
vault write -f transit/keys/order-pii            # 创建一把默认 key (aes256-gcm96)
vault read transit/keys/order-pii                # 看密钥元数据
```

返回的关键字段（对应 [Read key API](https://developer.hashicorp.com/vault/api-docs/secret/transit#read-key) 响应）：

| 字段 | 说明 |
| --- | --- |
| `name` | 密钥名（与 URL 中的 `:name` 一致） |
| `type` | 算法（默认 `aes256-gcm96`，详见 §5 类型矩阵） |
| `keys` | 已存在的版本号 → 创建时间 (Unix 秒) 映射；非对称 key 这里还会带 `public_key` 等元数据 |
| `latest_version` | 当前最高版本号；新加密默认走它（初始 = 1） |
| `min_decryption_version` | 解密时允许的最小版本（默认 1，可调；调高后低版本密文会被拒绝，旧版本 key material 会归档而非立刻删除） |
| `min_encryption_version` | 加密时允许的最小版本（默认 0 = 用 `latest_version`；非 0 时必须 ≥ `min_decryption_version`） |
| `deletion_allowed` | 默认 `false`——**默认整把 key 不能被删**，必须先 `update deletion_allowed=true` |
| `derived` | 是否启用密钥派生（见 §6.1）；启用后所有加/解密都必须传 `context` |
| `convergent_encryption` | 是否启用收敛加密（要求 `derived=true`，见 §6.2） |
| `exportable` | 是否允许 `export` 出原始密钥（默认 `false`，**一旦设 true 不可撤回**） |
| `allow_plaintext_backup` | 是否允许 `backup` 输出含明文 key 的备份（默认 `false`，**同样一旦开启不可撤回**） |
| `auto_rotate_period` | 自动轮转周期（duration 字符串，默认 `0` 表示禁用；最短 1 小时） |
| `imported` | 是否是通过 BYOK / `import` 导入的密钥（导入的 key 默认不可再次 rotate，除非 `allow_rotation=true`） |
| `supports_encryption` / `supports_decryption` | 由 `type` 推导：该 key 能否做加 / 解密（如 `ed25519` 两个都 `false`） |
| `supports_signing` | 该 key 能否做签名（仅非对称 key 为 `true`） |
| `supports_derivation` | 该 key 能否启用密钥派生（如 AES-GCM、ChaCha20、Ed25519 支持，ECDSA / RSA 不支持） |

> **`deletion_allowed=false` 是双保险**：避免误操作把整个引擎下所有用此 key 加密的密文一次性变废铁。
> 真要删，必须**两步**：先 update 允许删除，再 delete。

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
- `<base64-data>` Vault 生成的密文载荷；官方入门示例称其为 IV 与 ciphertext 的 base64 拼接，但不同算法 / 模式下内部布局可能不同，应用应把整个 `vault:v<N>:...` 当不透明字符串保存

> 应用只需要保存这个不透明字符串，无需关心算法、密钥、版本——这些都被 Vault 隐藏在路由后面。

### 3.1 批量接口

```bash
vault write -format=json transit/encrypt/order-pii - <<'EOF' | jq .data.batch_results
{
  "batch_input": [
    {"plaintext": "MTIz"},
    {"plaintext": "NDU2"}
  ]
}
EOF
```

返回 `batch_results` 数组对应 ciphertext，性能通常更高。

### 3.2 关联数据 (Context / Associated Data)

可以在加密时传 `context` 字段（仅当 key 是 `derived=true`，且必须 base64 编码）或 `associated_data`（AEAD cipher 的 AAD，覆盖 AES-GCM / ChaCha20-Poly1305，同样必须 base64 编码）。
这两个机制让"密文 + context / AAD"必须配对成功才能解密——典型场景：把租户 ID 绑进 `associated_data`，
让 A 租户密文绝不可能被 B 租户的解密路径破解。

在 CLI 里，`context` 就是 `vault write` 的一个参数。典型用法是先创建派生 key，然后加/解密两边都传同一个 base64 context；同一份明文在不同租户 context 下会得到彼此隔离的密文：

```bash
vault write -f transit/keys/tenant-pii derived=true

# 不传 context 会失败
vault write transit/encrypt/tenant-pii \
  plaintext=$(echo -n "13800138000" | base64) 2>&1 | tail -3
# 应报错：context is required for derived keys

B64=$(echo -n "13800138000" | base64)
CTX_A=$(echo -n "tenant-A" | base64)
CTX_B=$(echo -n "tenant-B" | base64)

CT_A=$(vault write -format=json transit/encrypt/tenant-pii \
  plaintext="$B64" context="$CTX_A" | jq -r .data.ciphertext)
echo "Tenant A 密文: $CT_A"

CT_B=$(vault write -format=json transit/encrypt/tenant-pii \
  plaintext="$B64" context="$CTX_B" | jq -r .data.ciphertext)
echo "Tenant B 密文: $CT_B"

# tenant-A 用自己的 context 解 A 的密文 → 成功
vault write -format=json transit/decrypt/tenant-pii \
  ciphertext="$CT_A" context="$CTX_A" | jq -r .data.plaintext | base64 -d
echo

# tenant-B 试图用自己的 context 解 A 的密文 → 失败
vault write transit/decrypt/tenant-pii \
  ciphertext="$CT_A" context="$CTX_B" 2>&1 | tail -3
# 应报错：cipher: message authentication failed 之类
```

如果直接调用 HTTP API，`associated_data` 不参与派生子密钥，而是作为 AEAD 的 AAD 被认证；解密时必须传入完全相同的 AAD：

```bash
curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{
    "plaintext": "MTM4MDAxMzgwMDA=",
    "associated_data": "dGVuYW50LUE="
  }' \
  $VAULT_ADDR/v1/transit/encrypt/order-pii

curl \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{
    "ciphertext": "vault:v1:...",
    "associated_data": "dGVuYW50LUE="
  }' \
  $VAULT_ADDR/v1/transit/decrypt/order-pii
```

如果传错 `context` 或 `associated_data`，Vault 会把这次解密视为认证失败；应用不应该把它当成“换个租户再试一次”的普通业务分支。

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

![transit-rewrap-no-plaintext](/images/ch3-transit/transit-rewrap-no-plaintext.png)

要让旧版本在常规解密路径中被拒绝：

```bash
vault write transit/keys/order-pii/config min_decryption_version=2
# 此后所有 vault:v1:... 解密都会被拒绝
```

这会把低于阈值的 key version 移出工作集并归档；紧急情况下仍可把 `min_decryption_version` 调回。
如果要不可恢复地删除旧版本，需要另用 `transit/keys/<name>/trim`，那是更危险的永久操作。

> 这个组合让密钥轮转**完全异步且零中断**：业务无须停机，按背景批处理速度逐步把 v1 密文升级到 v2，
> 做完后 `min_decryption_version=2` 停止接受旧版密文。

---

## 5. 密钥类型矩阵

`type` 字段决定 key 的算法和支持的操作：

> 官方文档有一个容易忽略的点：**所有 Transit key type 都会额外生成独立 HMAC key**，所以 `/transit/hmac` 并不只属于 `hmac` 类型；
> `hmac` 类型只是“只做 HMAC”的专用类型。CMAC 则是 Enterprise 的独立 `/transit/cmac` 操作。

| `type` | 算法族 | 加/解密 | 签/验签 | HMAC | 数据密钥 (DEK) | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| `aes128-gcm96` / `aes256-gcm96` | AES-GCM | ✅ | ❌ | ✅ | ✅ | 支持派生 / 收敛加密；`aes256-gcm96` 是默认类型 |
| `chacha20-poly1305` | ChaCha20-Poly1305 | ✅ | ❌ | ✅ | ✅ | 支持派生 / 收敛加密；FIPS 140-3 模式下不应使用 |
| `ed25519` | Ed25519 | ❌ | ✅ | ✅ | ❌ | 支持签名派生；FIPS 140-3 模式下不应使用 |
| `ecdsa-p256` / `ecdsa-p384` / `ecdsa-p521` | ECDSA | ❌ | ✅ | ✅ | ❌ | NIST P 曲线签名 key |
| `rsa-2048` / `rsa-3072` / `rsa-4096` | RSA | ✅ | ✅ (PSS/PKCS#1 v1.5) | ✅ | ✅ | 加/解密与 DEK 默认使用 OAEP；也支持 legacy `pkcs1v15` padding（不推荐，除非兼容旧系统） |
| `hmac` | HMAC | ❌ | ❌ | ✅ | ❌ | 仅 HMAC 生成 / 验证；支持导入，`key_size` 可配置 |
| `managed_key` | Managed Key | 仅部分后端 | ✅ | ✅ | 仅部分后端 | Enterprise；Sign / Verify 在 managed key 类型上支持较完整；Encrypt / Decrypt 目前主要只有 PKCS#11 managed keys 支持 |
| `aes128-cmac` / `aes192-cmac` / `aes256-cmac` | AES-CMAC | ❌ | ❌ | ✅ | ❌ | Enterprise；CMAC 走 `/transit/cmac`，验算时用 `cmac` 参数 |
| `ml-dsa` | ML-DSA | ❌ | ✅ | ✅ | ❌ | Enterprise 实验特性，后量子签名 |
| `hybrid` | Hybrid signatures | ❌ | ✅ | ✅ | ❌ | Enterprise 实验特性，后量子 + 椭圆曲线混合签名 |
| `slh-dsa` | SLH-DSA | ❌ | ✅ | ✅ | ❌ | Enterprise 实验特性，后量子签名 |
| `aes128-cbc` / `aes256-cbc` | AES-CBC | ✅ | ❌ | ✅ | ✅ | Enterprise；支持派生 / 收敛加密 |

创建非默认类型的 key：

```bash
vault write transit/keys/signing-key type=ed25519
```

---

## 6. 派生密钥 (`derived`) 与收敛加密

普通 key 加密同样的明文每次得到不同密文（因为 nonce / IV 等加密参数会随机生成）。
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

Vault 用内部 KDF 根据 master key 与 `context` 派生出子密钥后才加密。
**不同 `context` → 不同子密钥 → 密文互相不可解**——这就实现了"主密钥分一把、租户隔离"。
注意这里的 `context` 派生是 Transit 加/解密流程的一部分，和 API 里的 `/transit/derivedkeys` 数据密钥派生接口不是同一件事。

### 6.2 `convergent_encryption=true`：相同输入 → 相同密文

```bash
vault write -f transit/keys/searchable derived=true convergent_encryption=true
```

要求同时启用 `derived=true`。开启后，在同一 key/version 与相同 `context` 下，相同 plaintext 会得到相同密文——
Vault 会确定性派生 nonce，而不是每次随机生成 nonce；换来的能力是"密文上能做相等性查询"。
典型用途：在加密的 PII 字段上做 SQL `WHERE encrypted_phone = ?` 查询。

官方文档还提醒过历史版本差异：早期收敛加密 v1 需要客户端提供 nonce，v2 曾有离线明文确认攻击风险；新版本 key 可通过 rotate + rewrap 升级到 v3 算法。

> ⚠️ 收敛加密**会泄露明文相等性**——电话号码、身份证号这类低熵字段要特别谨慎，通常需要额外的威胁建模与访问控制，不能把它当成普通随机加密的等价替代品。

---

## 7. 数据密钥 (DEK) 模式：信封加密

![transit-dek-envelope](/images/ch3-transit/transit-dek-envelope.png)

加密大文件 / 大对象时，每次都把 GB 级数据送给 Vault 不现实。**信封加密** 解法：

1. **让 Vault 生成 DEK**（默认 256-bit 高熵数据密钥），并同时返回两份：明文 DEK + wrapped DEK
2. **本地用明文 DEK** 加密大数据（AES-GCM 等），用完尽快从内存中丢弃
3. 存：**密文大数据 + wrapped DEK**（也就是被 Transit key 加密过的 DEK）
4. 读时：先把 wrapped DEK 交给 Vault 解封，拿回明文 DEK
5. **本地用 DEK** 解密大数据

Vault 一站式接口：

```bash
# 生成 DEK：返回明文 DEK + 被 Transit key 包装后的 DEK
vault write -f transit/datakey/plaintext/order-pii
# Key            Value
# plaintext      <base64 of DEK>          ← 立刻用它本地加密大数据
# ciphertext     vault:v1:wrapped-dek...  ← 跟密文大数据一起存数据库

# 只生成 wrapped DEK，不返回 plaintext
vault write -f transit/datakey/wrapped/order-pii
# ciphertext     vault:v1:wrapped-dek...
# 适合让低权限流程预生成 wrapped DEK；它拿不到明文 DEK，不能直接加密业务数据

# 解封 wrapped DEK
vault write transit/decrypt/order-pii ciphertext=vault:v1:wrapped-dek...
# plaintext      <base64 of DEK>          ← 拿到后本地解密大数据
```

DEK 模式好处：

- **大数据从不经过 Vault** —— 性能与本地加密相当
- **被 Vault 锁定的 DEK 替代了"密钥分发"问题** —— 按主体撤销访问靠 Policy / Token；按版本淘汰旧 wrapped DEK 时再调 `min_decryption_version`
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

### 8.2 HMAC（Vault 托管的对称 MAC）

```bash
vault write transit/hmac/order-pii input=$(echo -n "msg" | base64)
# hmac  vault:v1:hmacresult...

vault write transit/verify/order-pii \
  input=$(echo -n "msg" | base64) \
  hmac=vault:v1:hmacresult...
# valid  true
```

> HMAC 与 Sign 的差别：HMAC 使用 Vault 为该 Transit key version 维护的独立 HMAC secret，生成和验证通常都经 `/transit/hmac` 与 `/transit/verify` 交给 Vault；
> Sign 使用私钥签名，选 ed25519 / ecdsa / rsa 时，Vault 持私钥，外部系统可用公钥验签。
> 只有在显式允许导出 `hmac-key` 时，外部系统才可能离线验 HMAC；默认不建议这么做。

### 8.3 读取 / 导出公钥

非对称 key 的公钥不是机密，但分发时仍要保证来源可信、内容未被替换。可以直接读 key 元数据；具备相应权限 / 配置时，也可以走 public-key export endpoint：

```bash
vault read transit/keys/signing-key
# keys.<version>.public_key   <按 key type 返回；ed25519 是 base64 原始公钥字节>

vault read transit/export/public-key/signing-key
# keys.<version>              <对应版本的公钥>
```

例如 `ed25519` 的 `public_key` 看起来会像 `RyOd/...=` 这样的 base64 字符串，
不是 `-----BEGIN PUBLIC KEY-----` PEM 块；离线验签时按对应算法格式解码 / 转换即可。

---

## 9. 路径与权限快速查阅

| 操作 | 路径 | Policy |
| --- | --- | --- |
| 启用 / 禁用 | `sys/mounts/transit` | `["create","read","update","delete"]` |
| 创建 / 配置 / 删除 key | `transit/keys/<name>` `transit/keys/<name>/config` | `["create","read","update","delete"]` |
| 加密 / 解密 | `transit/encrypt/<name>` `transit/decrypt/<name>` | 通常给 `["update"]`；`encrypt` 额外支持 `["create"]` 用于 key 不存在时 upsert |
| 轮转 | `transit/keys/<name>/rotate` | `["update"]` |
| Rewrap | `transit/rewrap/<name>` | `["update"]` |
| 数据密钥 | `transit/datakey/{plaintext,wrapped}/<name>` | `["update"]` |
| 签 / 验 / HMAC | `transit/sign/<name>` `transit/verify/<name>` `transit/hmac/<name>` | `["update"]` |
| 哈希 / 随机数 | `transit/hash(/<algorithm>)` `transit/random(/<source>)(/<bytes>)` | `["update"]` |
| Transit 全局 key 配置 | `transit/config/keys` | `["read","update"]`（如 `disable_upsert`） |

> **典型最小授权**：业务应用只给 `update` on `transit/encrypt/<name>` + `transit/decrypt/<name>`，
> **不给 `create/update` on `transit/keys/<name>`**——应用只能用密钥，无权改/删/换密钥。
> 若给了 `create` on `transit/encrypt/<name>`，未知 key 可能被自动创建；可用 `transit/config/keys disable_upsert=true` 关闭这种 upsert 能力。
> 密钥管理员另一套 Policy 持有创建/轮转/删除权限。

---

## 10. 安全默认与"不要删 key"

Transit 的几条**默认就严**的安全设定：

| 默认 | 含义 | 想改怎么办 |
| --- | --- | --- |
| `deletion_allowed=false` | key 不能被删除 | `vault write transit/keys/<name>/config deletion_allowed=true` 后再删 |
| `exportable=false` | 不能通过 `/transit/export` 导出原始 key material / HMAC key 等敏感材料 | 创建 key 时或之后通过 config update 设 `exportable=true`；一旦开启不可关闭 |
| `allow_plaintext_backup=false` | 默认拒绝 `/transit/backup/<name>` 这种含明文 key material 的备份 | 创建 key 时或之后通过 config update 设 `allow_plaintext_backup=true`；一旦开启不可关闭，备份会包含配置、所有版本 key 与 HMAC key |

> 强烈建议：除非有明确"key 必须出门"的合规要求，否则保持 `exportable=false` + `allow_plaintext_backup=false`。
> 这才是真正的"应用持密文，Vault 持钥匙——而且钥匙永不离开 Vault"。

---

## 11. BYOK 导入与 Key Wrapping

Transit 也支持 **Bring Your Own Key (BYOK)**：也就是把 Vault 外部生成的 key material 导入 Transit，让这把外部 key 后续像普通 Transit key 一样参与加密 / 解密。官方 key wrapping guide 的定位不是讲 `rewrap` 旧密文，而是讲“导入外部 key 之前，如何把目标 key 包装成 Vault 可接受的 import ciphertext”。[来源：key-wrapping-guide.mdx「import」开篇：BYOK allows users to import keys generated outside Vault；document describes wrapping an externally-generated key for import]

第一步仍然是启用 Transit 引擎；如果引擎已经启用，可以跳过这步。[来源：key-wrapping-guide.mdx「Mount the secrets engine」段]

```bash
# 来源：key-wrapping-guide.mdx「Mount the secrets engine」命令示例
vault secrets enable transit
```

然后读取 Transit 的 wrapping public key：`transit/wrapping_key` 会返回一把 4096-bit RSA 公钥。后续流程取决于目标 key 存在软件里，还是存在 HSM 里。[来源：key-wrapping-guide.mdx「Retrieve the transit wrapping key」段：vault read transit/wrapping_key；This returns a 4096-bit RSA key；steps depend on software or HSM]

```bash
# 来源：key-wrapping-guide.mdx「Retrieve the transit wrapping key」命令示例
vault read transit/wrapping_key
```

软件场景下，官方 Go 示例的核心流程是：解析 PEM 格式的 wrapping key，生成一把临时 AES key，用 AES-KWP 包装目标 key，再用 Transit 的 RSA wrapping key 通过 RSA-OAEP 包装这把临时 AES key。[来源：key-wrapping-guide.mdx「Software example (Go)」段：parse wrapping key with encoding/pem and crypto/x509；generate an ephemeral AES key；Tink KWP wraps target key；rsa.EncryptOAEP wraps ephemeral AES key]

临时 AES key 用完后要安全删除；官方示例特别提醒这一点，因为它短暂持有“能解开目标 key 包装层”的能力。[来源：key-wrapping-guide.mdx「Software example (Go)」note：Be sure to securely delete the ephemeral AES key once it has been used]

软件包装完成后，把 `wrappedAESKey` 和 `wrappedTargetKey` 拼接成一个字节串：最左边 4096 bits 是被 RSA-OAEP 包过的 AES key，剩余部分是被 AES-KWP 包过的目标 key；最后把整个字节串 base64 编码，作为 import 的 `ciphertext` 参数。[来源：key-wrapping-guide.mdx「Software example (Go)」段：concatenate wrapped keys；leftmost 4096 bits wrapped AES key；remaining bits wrapped target key；base64-encode]

```bash
# 来源：key-wrapping-guide.mdx「Software example (Go)」import 命令示例
vault write transit/keys/test-key/import \
  ciphertext=$CIPHERTEXT \
  hash_function=SHA256 \
  type=$KEY_TYPE
```

这里的 `hash_function` 要和包装临时 AES key 时 RSA-OAEP 使用的 hash 一致；官方 Go 示例用 `SHA256`，也说明 Vault 支持 `SHA1`、`SHA384`、`SHA512` 等选项。[来源：key-wrapping-guide.mdx「Software example (Go)」段：example uses SHA256；Vault also supports SHA1, SHA384, or SHA512；hash function must be provided when importing]

HSM 场景下，官方以 AWS CloudHSM 为例：先把 Transit 的 wrapping public key 写入 HSM，形成一个可用于 wrap 的 RSA public key object；如果使用别的 HSM 工具，也要确保 wrapping key 的用途包含 `CKA_WRAP`。[来源：key-wrapping-guide.mdx「AWS CloudHSM example」段：write transit wrapping key to HSM；importPubKey；usage includes CKA_WRAP]

```bash
# 来源：key-wrapping-guide.mdx「AWS CloudHSM example」importPubKey 命令示例
importPubKey -f wrapping_key.pem -l "vault-transit-wrapping-key"
```

之后在 HSM 内用 wrapping key 包目标 key；AWS CloudHSM 示例里的 `wrapKey -noheader ... -m 7` 使用 `CKM_AES_RSA_KEY_WRAP` 机制，`-t 3` 表示 `SHA256`，`-out ciphertext.key` 输出二进制包装结果。[来源：key-wrapping-guide.mdx「AWS CloudHSM example」wrapKey 段：wrap target key using wrapping key；-m 7 corresponds to CKM_AES_RSA_KEY_WRAP；-t 3 specifies SHA256；output ciphertext.key；noheader removes AWS-specific header]

```bash
# 来源：key-wrapping-guide.mdx「AWS CloudHSM example」wrapKey 命令示例
wrapKey -noheader -k 1 -w 2 -t 3 -m 7 -out ciphertext.key
```

HSM 输出通常是二进制文件，交给 Vault 前同样需要 base64 编码，再把结果作为 `ciphertext` 传给 `transit/keys/<name>/import`；导入完成后，这把 key 就可以像其它 Transit key 一样使用。[来源：key-wrapping-guide.mdx「AWS CloudHSM example」导入段：binary output needs base64-encoded；vault write transit/keys/test-key/import；Once imported, it can be used like any other transit key]

```bash
# 来源：key-wrapping-guide.mdx「AWS CloudHSM example」base64 与 import 命令示例
export CIPHERTEXT=$(base64 ciphertext.key)
vault write transit/keys/test-key/import \
  ciphertext=$CIPHERTEXT \
  hash_function=SHA256 \
  type=$KEY_TYPE
```

这套流程的重点是：Vault 不要求你把外部 key material 明文发给它，而是先用 Transit 的 wrapping public key 和约定的包装格式构造 `ciphertext`，再走 import endpoint；软件 key 与 HSM key 的差别主要在“包装动作由谁执行”。[来源：key-wrapping-guide.mdx「Software example (Go)」与「AWS CloudHSM example」整体流程：software uses Go crypto/Tink；HSM uses key_mgmt_util；both produce base64 ciphertext for transit/keys/test-key/import]

---

## 12. 与其它章节的关系

```
[3.2 KV v2]              ← 镜像对照：那是 Vault 替你存机密；这是 Vault 替你守钥匙
[3.4 Cubbyhole]          ← 都不靠"路径权限模型"，但分别为 Token 隔离 / 加密服务
[3.10/3.11 LDAP/K8s]     ← 那些都是"Vault 向外签发短期凭据"，本章是"Vault 提供算力"
[3.12 TOTP]              ← 同样是"密码学即服务"，TOTP 是时间一次性密码，Transit 是通用加解密+签名
```

---

## 13. 三个最容易踩的坑

1. **`plaintext` 必须 base64** —— 直接传明文字符串会被当成已编码、解出乱码。
   命令行务必 `$(echo -n "..." | base64)`，自动化里一定要 `--data-binary @-` 之类的姿势避免换行。

2. **删 key 不可逆，且会让所有密文变废铁** —— 默认 `deletion_allowed=false` 是良性保护。
   按主体撤销访问应撤销 Policy / Token；按版本淘汰旧密文才调 `min_decryption_version`；真正删 key 只适合明确要永久销毁所有相关密文的场景。

3. **轮转后忘了 rewrap，旧密文一直走旧版本解** —— 不会出错，但若旧版本被 `min_decryption_version` 关了就突然全失败。
   生产规范是**每次 rotate 后立即排程 rewrap**，再过几个保留周期才 raise `min_decryption_version`；若还要不可恢复地删旧版本，再谨慎使用 `trim`。

---

## 参考文献

- [Transit Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [Transit Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/transit)
- [Key wrapping for transit key import](https://developer.hashicorp.com/vault/docs/secrets/transit/key-wrapping-guide)
- [Tutorial - Encryption as a Service](https://developer.hashicorp.com/vault/tutorials/encryption-as-a-service/eaas-transit)
- [NIST SP 800-38D — GCM](https://csrc.nist.gov/publications/detail/sp/800-38d/final)、[RFC 8439 — ChaCha20-Poly1305](https://datatracker.ietf.org/doc/html/rfc8439)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-transit"/>
