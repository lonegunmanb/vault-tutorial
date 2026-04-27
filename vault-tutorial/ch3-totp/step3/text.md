# 第 3 步：Provider 模式 —— 让 Vault 替你校验外部生成的码

模型：[3.12 §4](/ch3-totp)。本步要：

1. `generate=false` 创建 key，secret 由调用者写入
2. 用 `oathtool` 在外部生成当前码
3. `vault write totp/code/<name> code=...` 让 Vault 校验
4. 演示 Provider key 不能被 `vault read` 出码（与 Step2 反向对照）

---

## 3.1 准备一个已知的 base32 secret

```bash
SECRET="JBSWY3DPEHPK3PXP"
echo "secret = $SECRET"
```

## 3.2 创建 Provider key

可以用两种等价语法：

**方式 A：传 url**

```bash
vault write totp/keys/web-2fa-bob \
  generate=false \
  url="otpauth://totp/MyApp:bob@example.com?secret=${SECRET}&issuer=MyApp&algorithm=SHA1&digits=6&period=30"
```

**方式 B：分开传 key + 元数据**

```bash
vault write totp/keys/web-2fa-bob \
  generate=false \
  key="$SECRET" \
  issuer="MyApp" \
  account_name="bob@example.com" \
  algorithm="SHA1" digits=6 period=30
```

两种都行，本实验用方式 B。

## 3.3 外部生成码 → Vault 校验

```bash
# 用 oathtool 生当前码
CODE=$(oathtool --totp -b "$SECRET")
echo "External code: $CODE"

# 让 Vault 校验
vault write totp/code/web-2fa-bob code="$CODE"
# Key     Value
# valid   true
```

试一个错码：

```bash
vault write totp/code/web-2fa-bob code=000000
# valid   false
```

## 3.4 试试 Provider key 不能被 `vault read code/...`

Provider 角色"只校不吐"：

```bash
vault read totp/code/web-2fa-bob 2>&1 | head -5
# 应得到错误，类似：key generation is disabled
```

## 3.5 模拟真实登录场景脚本

```bash
verify_user() {
  local user_key=$1
  local code=$2
  local result=$(vault write -format=json totp/code/$user_key code=$code 2>/dev/null | jq -r .data.valid)
  if [ "$result" = "true" ]; then
    echo "✅ User passed MFA"
    return 0
  else
    echo "❌ MFA failed"
    return 1
  fi
}

verify_user "web-2fa-bob" "$(oathtool --totp -b $SECRET)"
verify_user "web-2fa-bob" "111111"
```

---

## ✅ 验收

- [ ] 用 `key=$SECRET` 创建 Provider key 成功
- [ ] `oathtool` 生码 → `vault write totp/code/...` 返回 `valid: true`
- [ ] 错码返回 `valid: false`
- [ ] `vault read totp/code/<provider key>` 报错
