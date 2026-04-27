# 第 3 步：派生密钥与信封加密 (DEK) —— 加密大文件

模型：[3.13 §6 + §7](/ch3-transit)。本步要：

1. 创建 `derived=true` 的 key，演示"必须带 context"
2. 同明文不同 context → 互相解不开（租户隔离）
3. 用 `transit/datakey/plaintext` 拿到一对 (DEK plaintext, DEK ciphertext)
4. 本地用 openssl + DEK 加密 100 MB 文件，全程毫秒级
5. 通过 wrapped DEK 还原 → 本地解密 → 文件原样恢复

---

## 3.1 派生密钥：context 即租户

```bash
vault write -f transit/keys/multi-tenant derived=true

# 不传 context 加密会失败
vault write transit/encrypt/multi-tenant \
  plaintext=$(echo -n "secret" | base64) 2>&1 | tail -3
# 应报错：context is required for derived keys

# 给 tenant-A 加密
B64=$(echo -n "secret-data" | base64)
CTX_A=$(echo -n "tenant-A" | base64)
CTX_B=$(echo -n "tenant-B" | base64)

CT_A=$(vault write -format=json transit/encrypt/multi-tenant \
  plaintext="$B64" context="$CTX_A" | jq -r .data.ciphertext)
echo "Tenant A 密文: $CT_A"

# 给 tenant-B 加密同样的明文
CT_B=$(vault write -format=json transit/encrypt/multi-tenant \
  plaintext="$B64" context="$CTX_B" | jq -r .data.ciphertext)
echo "Tenant B 密文: $CT_B"
```

## 3.2 验证租户隔离

```bash
# tenant-A 用自己的 context 解 A 的密文 → 成功
vault write -format=json transit/decrypt/multi-tenant \
  ciphertext="$CT_A" context="$CTX_A" | jq -r .data.plaintext | base64 -d

# tenant-B 试图用自己 context 解 A 的密文 → 失败
vault write transit/decrypt/multi-tenant \
  ciphertext="$CT_A" context="$CTX_B" 2>&1 | tail -3
# 应报错：cipher: message authentication failed 之类
```

## 3.3 信封加密：本地 100 MB 文件

```bash
# 准备一个 100 MB 测试文件
dd if=/dev/urandom of=/tmp/big.bin bs=1M count=100 status=none
ls -lh /tmp/big.bin
md5sum /tmp/big.bin
```

向 Vault 申请一对 (DEK plaintext + DEK ciphertext)：

```bash
DK_RES=$(vault write -f -format=json transit/datakey/plaintext/order-pii)
echo "$DK_RES" | jq

DEK_PLAIN=$(echo "$DK_RES" | jq -r .data.plaintext)     # base64 of 32-byte key
DEK_WRAPPED=$(echo "$DK_RES" | jq -r .data.ciphertext)  # vault:v2:...

echo "DEK (base64): $DEK_PLAIN"
echo "Wrapped DEK : $DEK_WRAPPED"
```

本地用 openssl + DEK 加密大文件（注意：openssl 命令行用 hex 而非 base64 接收 key）：

```bash
DEK_HEX=$(echo "$DEK_PLAIN" | base64 -d | xxd -p -c 256)

# AES-256-CBC 演示。生产建议 AES-GCM 或 ChaCha20-Poly1305
openssl enc -aes-256-cbc -pbkdf2 \
  -in /tmp/big.bin -out /tmp/big.bin.enc \
  -K "$DEK_HEX" -iv "00000000000000000000000000000000"

ls -lh /tmp/big.bin.enc
```

**清理本地 DEK 明文**（演示安全做法）：

```bash
unset DEK_PLAIN DEK_HEX
```

模拟"过几个月后取回数据"：只剩下密文文件 + wrapped DEK。

## 3.4 还原流程

```bash
# 把 wrapped DEK 给 Vault 解封
DEK_PLAIN=$(vault write -format=json transit/decrypt/order-pii \
  ciphertext="$DEK_WRAPPED" | jq -r .data.plaintext)
DEK_HEX=$(echo "$DEK_PLAIN" | base64 -d | xxd -p -c 256)

# 本地解密
openssl enc -aes-256-cbc -pbkdf2 -d \
  -in /tmp/big.bin.enc -out /tmp/big.bin.recovered \
  -K "$DEK_HEX" -iv "00000000000000000000000000000000"

# 验证一致
md5sum /tmp/big.bin /tmp/big.bin.recovered
```

两个 md5 应完全一致。

## 3.5 wrapped 形式：连 DEK 都不要

如果应用还没准备好用 DEK（比如要存进数据库等待后续用），用 `wrapped` 接口只拿密文形式：

```bash
vault write -f -format=json transit/datakey/wrapped/order-pii | jq
# 只返回 ciphertext, 没 plaintext —— 更安全
```

需要用时再 `transit/decrypt/<name>` 解封即可。

---

## ✅ 验收

- [ ] `derived=true` key 不传 context 加密失败
- [ ] tenant-A 密文不能被 tenant-B 的 context 解开（HMAC 失败）
- [ ] `datakey/plaintext` 一次返回 (plaintext DEK + wrapped DEK)
- [ ] 本地 openssl + DEK 加密 100 MB 文件全程毫秒级（数据从不经过 Vault）
- [ ] 用 wrapped DEK 解封 → 本地解密 → md5 与原文件一致
- [ ] `datakey/wrapped` 返回的结果不含 plaintext
