# 第 5 步：BYOK 导入外部密钥 —— wrapping_key + import

模型：[3.13 §11](/ch3-transit)。本步要：

1. 读取 Transit 的 `wrapping_key`，确认它是给导入流程用的 RSA 公钥
2. 在本地生成一把 32-byte AES-256 外部密钥
3. 用 `vault transit import` helper 走 BYOK 包装 + 导入流程
4. 读取导入后的 key 元数据，确认 `imported=true`
5. 像普通 Transit key 一样用导入 key 加密 / 解密

---

## 5.1 先看 wrapping key

```bash
vault read transit/wrapping_key
```

这个 endpoint 返回的是 Transit 用于导入流程的 4096-bit RSA **公钥**。
外部 key material 不应该明文直接交给 Vault；正确流程是用这把公钥参与包装，然后把包装后的 `ciphertext` 发给 import endpoint。

> 官方 key wrapping guide 展示了 Go / HSM 手动包装流程；Vault CLI 也内置了 helper，可以替我们完成“读取 wrapping key → 生成临时包装 key → 包装目标 key → 提交 import”的步骤。

## 5.2 准备一把外部 AES-256 key

为了让本步能重复执行，先清理同名测试 key：

```bash
vault write transit/keys/byok-aes/config deletion_allowed=true >/dev/null 2>&1 || true
vault delete transit/keys/byok-aes >/dev/null 2>&1 || true
```

生成一把 32-byte 随机 key，并按 Transit import helper 要求保存为标准 base64：

```bash
BYOK_KEY_B64=$(openssl rand -base64 32)
echo "$BYOK_KEY_B64" > /tmp/byok-aes256.b64

echo "外部 key(base64): $BYOK_KEY_B64"
echo "$BYOK_KEY_B64" | base64 -d | wc -c
# 应输出 32
```

这把 key 是在 Vault 外部生成的。真实生产里它可能来自 HSM、KMS、旧系统或离线密钥生成流程；这里用 `openssl rand` 模拟。

## 5.3 用 CLI helper 导入

```bash
vault transit import transit/keys/byok-aes @/tmp/byok-aes256.b64 type=aes256-gcm96
```

你应该看到类似输出：

```text
Retrieving transit wrapping key.
Wrapping source key with ephemeral key.
Encrypting ephemeral key with transit wrapping key.
Submitting wrapped key to Vault transit.
Success!
```

这几行就是 §11 里 key wrapping 流程的浓缩版：CLI 在本地拿外部 key 做包装，只把包装后的材料交给 Vault。

## 5.4 确认它是一把 imported Transit key

```bash
vault read -format=json transit/keys/byok-aes | jq '.data | {
  name,
  type,
  imported,
  latest_version,
  supports_encryption,
  supports_decryption
}'
```

重点看：

- `type` 应为 `aes256-gcm96`
- `imported` 应为 `true`
- `supports_encryption` / `supports_decryption` 应为 `true`

导入成功后，应用侧不需要知道这把 key 是 Vault 生成的还是外部导入的；使用路径还是 `transit/encrypt/<name>` 与 `transit/decrypt/<name>`。

## 5.5 用导入 key 加密 / 解密

```bash
B64=$(echo -n "secret-from-imported-key" | base64)

BYOK_CT=$(vault write -format=json transit/encrypt/byok-aes \
  plaintext="$B64" | jq -r .data.ciphertext)
echo "BYOK 密文: $BYOK_CT"

vault write -format=json transit/decrypt/byok-aes \
  ciphertext="$BYOK_CT" | jq -r .data.plaintext | base64 -d
echo
```

应输出原文：

```text
secret-from-imported-key
```

至此你验证了 BYOK 的核心效果：key material 来自 Vault 外部，但导入后仍通过 Transit 的统一 API 提供加密服务。

## 5.6 清理本地明文 key

导入完成后，本地那份 base64 key material 已经不该继续留着：

```bash
shred -u /tmp/byok-aes256.b64 2>/dev/null || rm -f /tmp/byok-aes256.b64
unset BYOK_KEY_B64 B64 BYOK_CT
```

> 清理本地副本不等于删除 Vault 里的 imported key；Vault 里的 key 仍然存在于 `transit/keys/byok-aes`。

---

## ✅ 验收

- [ ] `vault read transit/wrapping_key` 能看到 RSA public key
- [ ] 本地生成的外部 key 解码后是 32 bytes
- [ ] `vault transit import ... type=aes256-gcm96` 成功
- [ ] `vault read transit/keys/byok-aes` 显示 `imported=true`
- [ ] `transit/encrypt/byok-aes` / `transit/decrypt/byok-aes` 能正常加解密
- [ ] 本地 `/tmp/byok-aes256.b64` 已清理
