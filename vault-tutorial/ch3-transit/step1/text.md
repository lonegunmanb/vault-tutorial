# 第 1 步：启用 transit/ 与第一次加解密

模型：[3.13 §2 + §3](/ch3-transit)。本步要：

1. 创建第一把 key（默认 `aes256-gcm96`）
2. 用 `transit/encrypt/<key>` 加密一个明文（注意 base64！）
3. 看清 `vault:v1:<data>` 密文格式，理解 `v1` 是版本号
4. 用 `transit/decrypt/<key>` 还原明文
5. 同样的明文加密两次得到不同密文（GCM 模式 nonce 随机）

---

## 1.1 引擎与首把 key

```bash
vault secrets list | grep -E "Path|transit"
vault write -f transit/keys/order-pii
vault read transit/keys/order-pii
```

注意 `keys` 字段：`{"1": <时间戳>}` 表明这把 key 当前版本是 1。

## 1.2 第一次加密

```bash
PLAINTEXT="13800138000"
B64=$(echo -n "$PLAINTEXT" | base64)
echo "base64 of plaintext: $B64"

CT=$(vault write -format=json transit/encrypt/order-pii \
  plaintext="$B64" | jq -r .data.ciphertext)
echo "Ciphertext: $CT"
```

`CT` 形如 `vault:v1:<base64-data>`：

- `vault:` 命名空间前缀
- `v1` 表示用版本 1 加密
- 后面是密文 + nonce + 认证标签

## 1.3 解密

```bash
PT_B64=$(vault write -format=json transit/decrypt/order-pii \
  ciphertext="$CT" | jq -r .data.plaintext)
echo "Plaintext base64: $PT_B64"
echo "Plaintext       : $(echo $PT_B64 | base64 -d)"
```

应得到原始的 `13800138000`。

## 1.4 同明文加密两次得不同密文

```bash
CT_A=$(vault write -format=json transit/encrypt/order-pii plaintext="$B64" | jq -r .data.ciphertext)
CT_B=$(vault write -format=json transit/encrypt/order-pii plaintext="$B64" | jq -r .data.ciphertext)
echo "CT_A: $CT_A"
echo "CT_B: $CT_B"
[ "$CT_A" != "$CT_B" ] && echo "✅ 同明文 → 不同密文 (因为 nonce 随机)"
# 但都能解出同样的明文
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_A" | jq -r .data.plaintext | base64 -d
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_B" | jq -r .data.plaintext | base64 -d
```

## 1.5 批量接口

```bash
vault write transit/encrypt/order-pii \
  batch_input='[
    {"plaintext": "MTIz"},
    {"plaintext": "NDU2"},
    {"plaintext": "Nzg5"}
  ]' -format=json | jq .data.batch_results
```

返回 3 个独立密文，性能比 3 次单条快很多（一次 RTT）。

---

## ✅ 验收

- [ ] `vault read transit/keys/order-pii` 显示 `latest_version: 1`
- [ ] 加密返回的 ciphertext 形如 `vault:v1:...`
- [ ] 解密能还原原始 base64，`base64 -d` 得回 `13800138000`
- [ ] 同明文两次加密得到不同密文（nonce 随机）
- [ ] `batch_input` 批量加密一次返回多个密文
