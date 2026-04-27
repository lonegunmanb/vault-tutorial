# 第 1 步：启用 totp/ 引擎，复习 RFC 6238 算法

模型：[3.12 §1 + §2](/ch3-totp)。本步要：

1. 确认 `totp/` 引擎已启用
2. 用 `oathtool` 手动跑一次 TOTP 算法，建立"30 秒窗口、6 位数字、HMAC-SHA1"的肌肉记忆
3. 记下"全世界用同一个 secret + 当前时间，得到的码必然相同"这条不变量

---

## 1.1 引擎状态

```bash
vault secrets list | grep -E "Path|totp"
```

应能看到 `totp/    totp    ...`。

## 1.2 用 oathtool 手算一次 TOTP

`oathtool` 接受一个 base32 secret + `--totp` 标志，输出当前 30 秒窗口的 6 位码：

```bash
SECRET="JBSWY3DPEHPK3PXP"     # base32 of "Hello!\xDE\xAD\xBE\xEF"
oathtool --totp -b "$SECRET"
# 输出: 一个 6 位数字
```

立刻再跑一次（应得到同样的码——除非你恰好跨过 30 秒边界）：

```bash
oathtool --totp -b "$SECRET"
```

等 30 秒后再跑（必然是不同的码）：

```bash
sleep 31 && oathtool --totp -b "$SECRET"
```

## 1.3 同一个 secret 的过去/未来码

`oathtool` 的 `--now` 可以模拟某个时间点：

```bash
oathtool --totp -b "$SECRET" --now="2024-01-01 00:00:00 UTC"
oathtool --totp -b "$SECRET" --now="2024-01-01 00:00:30 UTC"   # 下一个窗口
oathtool --totp -b "$SECRET" --now="2024-01-01 00:00:00 UTC" --window=2
# 最后一条会输出 3 个连续窗口的码 (now, now+30s, now+60s)
```

**核心不变量**：相同的 `(secret, time-window)` 组合在任何机器上得到的 6 位码必然相同。
这就是为什么 Vault 与 Authenticator App、与 oathtool、与 Google Authenticator 之间能互相校验。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `totp/`
- [ ] `oathtool --totp -b ...` 输出 6 位码
- [ ] 立即再跑一次得到同样的码（同一窗口）
- [ ] 等 31 秒后跑得到不同的码（下一窗口）
