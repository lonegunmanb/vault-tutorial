# 第 2 步：密钥版本化 —— rotate + rewrap + min_decryption_version

模型：[3.13 §4](/ch3-transit)。本步要：

1. 加密一些 v1 密文留存
2. `rotate` 让 key 升到 v2
3. 验证：旧 v1 密文仍能解；新加密自动 v2
4. `rewrap` 把 v1 升级到 v2，无需明文
5. `min_decryption_version=2` 一刀关掉 v1，旧密文立刻不可解

---

## 2.1 制造 v1 密文

```bash
B64=$(echo -n "v1-secret-data" | base64)
CT_V1=$(vault write -format=json transit/encrypt/order-pii plaintext="$B64" | jq -r .data.ciphertext)
echo "v1 密文: $CT_V1"
```

确认前缀：

```bash
echo "$CT_V1" | grep -oE "^vault:v[0-9]+:" 
# 应输出: vault:v1:
```

## 2.2 轮转

```bash
vault write -f transit/keys/order-pii/rotate
vault read transit/keys/order-pii
# latest_version: 2
# keys: {"1": ..., "2": ...}
```

## 2.3 验证：v1 旧密文照常解

```bash
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_V1" \
  | jq -r .data.plaintext | base64 -d
# 应输出 v1-secret-data
```

## 2.4 新加密自动用 v2

```bash
B64_V2=$(echo -n "v2-secret-data" | base64)
CT_V2=$(vault write -format=json transit/encrypt/order-pii plaintext="$B64_V2" | jq -r .data.ciphertext)
echo "$CT_V2" | grep -oE "^vault:v[0-9]+:"
# 应输出 vault:v2:
```

## 2.5 rewrap：把 v1 密文升级到 v2，无需明文

```bash
CT_REWRAPPED=$(vault write -format=json transit/rewrap/order-pii ciphertext="$CT_V1" | jq -r .data.ciphertext)
echo "Rewrap 后的密文: $CT_REWRAPPED"
echo "$CT_REWRAPPED" | grep -oE "^vault:v[0-9]+:"
# 应输出 vault:v2:

# 解密验证内容不变
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_REWRAPPED" \
  | jq -r .data.plaintext | base64 -d
# 应输出 v1-secret-data （内容来自 v1 密文，但现在用 v2 加密）
```

## 2.6 min_decryption_version 一刀关掉 v1

```bash
# 关掉 v1 解密
vault write transit/keys/order-pii/config min_decryption_version=2
vault read transit/keys/order-pii | grep min_decryption_version

# 试解原始 CT_V1（已被 rewrap 之前那个）
vault write transit/decrypt/order-pii ciphertext="$CT_V1" 2>&1 | tail -3
# 应得到错误：ciphertext or signature version is disallowed by policy
```

而被 rewrap 后的 v2 密文照常工作：

```bash
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_REWRAPPED" \
  | jq -r .data.plaintext | base64 -d
```

## 2.7 (可选) 把 min 调回去看 v1 复活

```bash
vault write transit/keys/order-pii/config min_decryption_version=1
vault write -format=json transit/decrypt/order-pii ciphertext="$CT_V1" \
  | jq -r .data.plaintext | base64 -d
# v1-secret-data 又能解了
```

> 这条"可逆"性恰恰说明 `min_decryption_version` **不是真的删 key**——只是路由层挡了。
> 真要让 v1 永远不可恢复，必须 `vault write transit/keys/<name>/trim min_available_version=2` 真清掉。

---

## ✅ 验收

- [ ] `rotate` 后 `latest_version: 2`，`keys` 含 1 和 2
- [ ] v1 旧密文仍可解
- [ ] 新加密自动生成 `vault:v2:` 前缀
- [ ] `rewrap` 把 v1 密文转换为 v2，**无需明文**
- [ ] `min_decryption_version=2` 后旧 v1 密文解密被拒
- [ ] 把 min 调回 1 后 v1 复活（说明只是路由层挡）
