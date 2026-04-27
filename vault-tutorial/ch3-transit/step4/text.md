# 第 4 步：签名 / 验签 / HMAC + 删除 key 的双保险

模型：[3.13 §8 + §10](/ch3-transit)。本步要：

1. 创建 `ed25519` key 做非对称签名 / 验签
2. 导出公钥，看到任何持公钥的方都能独立验签
3. 用对称 key 做 HMAC，对照"对称签名"
4. 体验 `deletion_allowed=false` 的双保险，正确删除一把 key

---

## 4.1 创建 ed25519 签名 key

```bash
vault write transit/keys/signing-key type=ed25519
vault read transit/keys/signing-key
```

注意输出含 `keys.<version>.public_key` 字段——这是可以无害对外发布的公钥。

## 4.2 签名一份消息

```bash
MSG="transfer 100 USD to alice"
B64=$(echo -n "$MSG" | base64)

SIG=$(vault write -format=json transit/sign/signing-key \
  input="$B64" | jq -r .data.signature)
echo "Signature: $SIG"
# 形如 vault:v1:base64sig...
```

## 4.3 验签

正确验签：

```bash
vault write transit/verify/signing-key \
  input="$B64" \
  signature="$SIG"
# valid  true
```

被篡改的消息：

```bash
TAMPERED=$(echo -n "transfer 100 USD to MALLORY" | base64)
vault write transit/verify/signing-key \
  input="$TAMPERED" \
  signature="$SIG"
# valid  false
```

## 4.4 导出公钥，独立验签 (概念)

```bash
PUBKEY=$(vault read -format=json transit/keys/signing-key | jq -r '.data.keys."1".public_key')
echo "$PUBKEY"
# -----BEGIN PUBLIC KEY-----
# ...
# -----END PUBLIC KEY-----
```

> 这个公钥可以发到任何不可信环境（CDN、客户端、第三方系统）。
> 持公钥方可以用 `openssl pkeyutl -verify -pubin -inkey pubkey.pem -sigfile sig -in msg`
> 等本地工具独立验签——**完全不需要再回 Vault**。这就是非对称签名相对 HMAC 的最大优势：
> 验签方不需要密钥。

## 4.5 HMAC：对称 key 的"签名"

```bash
HMAC=$(vault write -format=json transit/hmac/order-pii \
  input=$(echo -n "msg-to-mac" | base64) | jq -r .data.hmac)
echo "HMAC: $HMAC"
# vault:v2:hmacresult...

# 验证
vault write transit/verify/order-pii \
  input=$(echo -n "msg-to-mac" | base64) \
  hmac="$HMAC"
# valid  true

# 被改动的内容
vault write transit/verify/order-pii \
  input=$(echo -n "msg-to-MAC" | base64) \
  hmac="$HMAC"
# valid  false
```

> HMAC 与 sign 的区别：HMAC 用对称 key（双方都需要 key 才能验），sign 用私钥（公钥发出去验）。
> 持有 HMAC 验证能力 = 持有伪造能力。

## 4.6 删除 key 的双保险

直接删默认会失败：

```bash
vault delete transit/keys/order-pii 2>&1 | tail -3
# 应看到: cannot delete key "order-pii" — deletion is not enabled for this key
```

正确流程：

```bash
# 1) 先解锁删除
vault write transit/keys/order-pii/config deletion_allowed=true

# 2) 再删
vault delete transit/keys/order-pii
```

**确认连 root 也无法恢复**：

```bash
vault read transit/keys/order-pii 2>&1 | tail -3
# encryption key not found
```

之前用 `order-pii` 加密的所有密文（`vault:v1:...`、`vault:v2:...`）从此**全部成为永久不可解的废比特**。
这就是默认 `deletion_allowed=false` 的根本理由——避免"一次手抖灭九族"。

> 这一刀也是撤销访问最彻底的方式：撤 Token / 改 Policy 都还能走"灰色路径"，
> **删 key 让所有持密文者瞬间一无所获**。但代价是不可逆，生产慎用。

---

## ✅ 验收

- [ ] `ed25519` key 能签名 + 验签
- [ ] 篡改后的消息验签返回 `valid: false`
- [ ] 公钥可从 `vault read transit/keys/<name>` 取出
- [ ] `hmac` 与 `verify ... hmac=` 配对工作
- [ ] `vault delete transit/keys/...` 默认被拒
- [ ] 设 `deletion_allowed=true` 后才能删；删后所有密文不可恢复
