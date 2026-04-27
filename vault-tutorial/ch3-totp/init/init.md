# 实验：TOTP 机密引擎的两种角色全验证

[3.12 TOTP 机密引擎](/ch3-totp) 把 Generator 与 Provider 两种角色及其全部字段讲清楚了。
本实验在 Dev 模式 Vault 上把两种角色全跑一遍，并用**完全独立的第三方工具 `oathtool`**
（Linux 上用得最广的 RFC 6238 实现）从外部反向校验 Vault 的算法行为。

---

## 实验环境

后台脚本会自动准备好：

- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- **`totp/` 引擎已启用**
- 工具：
  - `oathtool` —— 独立的 RFC 4226/6238 实现（用来"对答案"）
  - `qrencode` —— 把 `otpauth://` URL 转 QR 码（在终端 ASCII 显示）
  - `jq` —— JSON 解析
  - `base64` —— 解码 Vault 返回的 barcode PNG

---

## 你将亲手验证的事实

1. **算法等价**：Vault Generator 在某个 30 秒窗口内输出的 6 位码 = `oathtool` 用同一 secret 输出的 6 位码
2. **角色二选一不可换**：Generator key 不能 `vault write code=...`，Provider key 不能 `vault read code/...`
3. **`skew=1` 给 ±30 秒容忍**：上一个/下一个窗口的码也接受，但更早就被拒
4. **`exported=false` 锁死 secret**：连 root 都读不出 url/secret，只能用、不能复制
5. **过期码被拒**：等 35 秒，再用旧码 → `valid: false`

预期耗时：10 ~ 15 分钟。
