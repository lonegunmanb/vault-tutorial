# 第 2 步：Generator 模式 —— 让 Vault 替你做 Authenticator

模型：[3.12 §3](/ch3-totp)。本步要：

1. `generate=true` 创建 key，让 Vault 自己生 secret
2. `vault read totp/code/<name>` 拿到当前 6 位码
3. 用 **oathtool 用 Vault 返回的 secret 自己跑一遍** —— 验证两边算出来的码一致
4. 把 `otpauth://` URL 转成 QR 码在终端 ASCII 渲染（如果你想用真手机 App 扫，也能扫得到）

---

## 2.1 创建 Generator key

```bash
RES=$(vault write -format=json totp/keys/my-bank \
  generate=true \
  issuer="MyBank" \
  account_name="alice@example.com" \
  exported=true \
  qr_size=200)
echo "$RES" | jq

URL=$(echo "$RES" | jq -r .data.url)
BARCODE=$(echo "$RES" | jq -r .data.barcode)

echo "URL: $URL"
```

`URL` 的形状大致：`otpauth://totp/MyBank:alice@example.com?secret=XXXXX...&issuer=MyBank&algorithm=SHA1&digits=6&period=30`

## 2.2 把 barcode 解码成 PNG，并用 qrencode 在终端显示 QR 码

```bash
echo "$BARCODE" | base64 -d > /tmp/my-bank.png
ls -la /tmp/my-bank.png   # 这就是可以发给用户扫描的 PNG

# 或者用 qrencode 在终端直接画 ASCII QR 码（不依赖图形）
qrencode -t ANSIUTF8 "$URL"
```

## 2.3 拿当前 6 位码

```bash
vault read totp/code/my-bank
# Key     Value
# code    654321
```

## 2.4 验证 Vault 与 oathtool 算的码一致

提取 secret，跑 oathtool：

```bash
SECRET=$(echo "$URL" | sed -E 's/.*secret=([^&]+).*/\1/')
echo "Secret (base32): $SECRET"

# Vault 算的码
VAULT_CODE=$(vault read -format=json totp/code/my-bank | jq -r .data.code)

# oathtool 用同样的 secret 算
OATH_CODE=$(oathtool --totp -b "$SECRET")

echo "Vault code   : $VAULT_CODE"
echo "oathtool code: $OATH_CODE"
[ "$VAULT_CODE" = "$OATH_CODE" ] && echo "✅ 算法等价"
```

(注意：如果两次读取跨过了 30 秒窗口边界，结果可能不同——再跑一次即可。)

## 2.5 试试 Generator key 不能被"校验"

Generator 角色只能让 Vault **吐码**，不能让它**校码**：

```bash
vault write totp/code/my-bank code=000000 2>&1 | head -5
# 应得到错误：unsupported operation 或 key was generated, validation not supported
```

这就是 [3.12 §2](/ch3-totp) 强调的"二选一不可换"。

---

## ✅ 验收

- [ ] `vault write totp/keys/my-bank generate=true ...` 返回了 url + barcode
- [ ] `qrencode -t ANSIUTF8 "$URL"` 在终端显示出 QR 码
- [ ] `vault read totp/code/my-bank` 与 `oathtool --totp -b $SECRET` 在同一窗口内输出相同码
- [ ] `vault write totp/code/my-bank code=...` 报错（Generator 不支持校验）
