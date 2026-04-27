# 第 4 步：`exported=false` 锁死 + 时钟容忍 (`skew`) + 过期码

模型：[3.12 §3 + §5 + §9 第 3 条](/ch3-totp)。本步要：

1. 创建 `exported=false` 的 Generator key，验证连 root 都拿不到 secret/url
2. 用 `skew` 实验时钟容忍：默认 ±1 个窗口；改成 0 后只接受当前窗口
3. 让一个码过 60+ 秒"老掉"，验证 Vault 拒绝它

---

## 4.1 `exported=false` 锁死

```bash
RES=$(vault write -format=json totp/keys/locked-key \
  generate=true \
  issuer="LockedDemo" \
  account_name="user@example.com" \
  exported=false)
echo "$RES" | jq
```

注意返回里**不再有 `url` 或 `barcode`**——只有元数据。

```bash
# 即使 root 也读不出 secret 或 url
vault read totp/keys/locked-key
# 输出只有 algorithm/digits/period/issuer 等公开字段，没 url/key
```

但仍然能让 Vault 出码：

```bash
vault read totp/code/locked-key
# code  XXXXXX
```

> **这等于把 Vault 变成了不可逃逸的 Authenticator**——secret 永远关在 Vault 里，
> 没有任何路径能导出，连备份都不行。生产环境慎用，必须先确认你能接受"删了重建"作为唯一恢复方案。

## 4.2 时钟容忍：`skew` 实验

创建两个 Provider key，一个 `skew=1`（默认），一个 `skew=0`：

```bash
SECRET="JBSWY3DPEHPK3PXP"

vault write totp/keys/skew-default \
  generate=false key="$SECRET" issuer=Skew account_name=u skew=1

vault write totp/keys/skew-strict \
  generate=false key="$SECRET" issuer=Skew account_name=u skew=0
```

用上一个窗口的码：

```bash
PREV_CODE=$(oathtool --totp -b "$SECRET" --now="$(date -u -d '40 seconds ago' '+%Y-%m-%d %H:%M:%S UTC')")
echo "上一个窗口的码: $PREV_CODE"

# skew=1 应接受
vault write totp/code/skew-default code="$PREV_CODE"

# skew=0 应拒绝
vault write totp/code/skew-strict code="$PREV_CODE"
```

## 4.3 过期码被拒

```bash
SECRET="JBSWY3DPEHPK3PXP"
vault write totp/keys/expiry-demo \
  generate=false key="$SECRET" issuer=Demo account_name=u skew=1 > /dev/null

# 拿当前码
CODE=$(oathtool --totp -b "$SECRET")
echo "刚生成的码: $CODE"

# 立刻校验 → true
vault write totp/code/expiry-demo code="$CODE"

# 等 70 秒（跨过 2 个 30s 窗口，超出 skew=1 容忍）
echo "等 70 秒，让码彻底老掉..."
sleep 70

# 再校验 → false
vault write totp/code/expiry-demo code="$CODE"
```

## 4.4 同一码两次都被接受？—— 不防重放

值得注意的设计：**TOTP 引擎不防重放**。同一个码在 `skew` 窗口内可以被多次校验为 true。
RFC 6238 规定"应由调用方记下已用过的码并拒重复"，Vault 不替你做这件事。

简单验证：

```bash
SECRET="JBSWY3DPEHPK3PXP"
vault write totp/keys/replay-demo \
  generate=false key="$SECRET" issuer=Demo account_name=u > /dev/null

CODE=$(oathtool --totp -b "$SECRET")

vault write totp/code/replay-demo code="$CODE"   # valid: true
vault write totp/code/replay-demo code="$CODE"   # valid: true (再次也通过！)
```

> **生产实现要点**：业务侧务必维护"用户最近 N 分钟用过的 6 位码"集合，命中即拒绝。
> Vault 只负责"算法对不对"，不负责"是不是用过了"。

---

## ✅ 验收

- [ ] `exported=false` 的 key 即使 root 也读不出 url/secret
- [ ] `skew=1` 接受上一个窗口的码，`skew=0` 拒绝
- [ ] 等 70 秒后旧码被拒（`valid: false`）
- [ ] 同一个码在 skew 窗口内**可被多次校验为 true** —— Vault 不防重放
