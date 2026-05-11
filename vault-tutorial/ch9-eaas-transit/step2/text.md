# 第 2 步：无中断密钥轮转——`rotate` 增版本、`rewrap` 升级存量密文

本步要演示 transit 引擎最重要的运维能力之一：**密钥轮转不需要让任何一条业务密文重新过一遍明文**。具体路线是：

1. 调 `transit/keys/payments/rotate` 给 `payments` 这把密钥追加一个新版本（`v2`）；
2. 写一笔新记录，验证它被自动用 `v2` 加密；
3. 验证旧记录（`v1` 加密）仍然能正常解密；
4. 调用应用的 `/admin/rewrap` 端点，把所有旧密文重新封装到当前最新版本——这一过程在 Vault 内部完成解密 + 重新加密，**应用与运维都看不到明文**。

## 2.1 触发一次密钥轮转

```bash
vault write -f transit/keys/payments/rotate
vault read transit/keys/payments
```

预期：返回的 `keys` 字段从原来的 `{"1": <ts>}` 变成 `{"1": <ts>, "2": <ts>}`，`latest_version` 变成 `2`。

> 关键概念：`rotate` 是**追加新版本**而非替换旧版本。版本 `1` 的密钥材料仍保留在 Vault 里，因此第 1 步用 `v1` 加密的那两条记录现在仍然能正常解密。

## 2.2 写一笔新记录，验证它使用 `v2`

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"name":"Bob","cc_info":"3782822463100005"}' \
  http://127.0.0.1:8080/payments
echo
```

预期返回的 `cc_info` 字段以 `vault:v2:` 开头——证明 transit 引擎对新加密自动使用最新版本：

```json
[{"id":"...","name":"Bob","cc_info":"vault:v2:...","createdAt":"..."}]
```

直接看一眼数据库里现在的版本分布（用 `substring` 只截前 10 个字符方便观察）：

```bash
psql -c "SELECT id, substring(cc_info, 1, 10) AS prefix FROM payments;"
```

预期：第 1 步写入的两条记录前缀仍是 `vault:v1:`、本步刚写入的这条是 `vault:v2:`。

## 2.3 旧密文仍可解

```bash
curl -s http://127.0.0.1:8080/payments
echo
```

三条记录的 `cc_info` 字段都应能正常返回明文卡号——证明轮转没有破坏任何已经在库的密文。

## 2.4 用 `/admin/rewrap` 把所有旧密文升级到 `v2`

应用代码里的 `/admin/rewrap` 端点会遍历 `payments` 表，对每条 `cc_info` 调用 `transit/rewrap/payments`。`rewrap` 接口是 transit 引擎给运维准备的『就地重新封装』API：把旧版本密文丢给它，它在 Vault 内部解出明文、用最新版本密钥重新加密、再返回新的 `vault:vN:...` 字符串——**调用方从头到尾都拿不到明文**。本应用收到新密文后，立刻 `UPDATE` 回数据库的 `cc_info` 列。

```bash
curl -s -X POST http://127.0.0.1:8080/admin/rewrap
echo
psql -c "SELECT id, substring(cc_info, 1, 10) AS prefix FROM payments;"
```

预期返回类似：

```json
{"rewrapped":3,"total":3}
```

> **为什么 `rewrapped` 是 3 而不是 2？** 因为 transit 引擎使用 GCM 模式，每次加密会生成一个全新的随机 nonce，所以即便目标密钥版本相同（第 2.2 节那条本来已经是 `v2`），`rewrap` 返回的密文字节也与原密文不同。应用代码用『密文是否变化』来判断是否需要 UPDATE，所以三条都被计入。这并不影响安全性——它只是说明 nonce 的随机性。

数据库里所有 `cc_info` 现在都应当以 `vault:v2:` 开头。

再读一次确认明文还原仍然正常：

```bash
curl -s http://127.0.0.1:8080/payments | head -c 400; echo
```

仍应得到带明文卡号的 JSON 列表。

## 2.5 用 `min_decryption_version` 一刀关旧版（可选演示）

存量密文都升级到 `v2` 之后，若希望 Vault 完全拒绝任何 `v1` 密文（防止有遗漏 / 攻击者拿着旧备份），可调高 `min_decryption_version`：

```bash
vault write transit/keys/payments/config min_decryption_version=2
vault read transit/keys/payments | grep min_decryption_version
```

预期 `min_decryption_version` 字段变为 `2`。从此刻起，任何 `vault:v1:...` 密文走 `transit/decrypt/payments` 都会被 Vault 直接拒绝——这正是 [3.13 节](/ch3-transit) 提到的『一刀关旧版』。

如要恢复（避免影响后续步骤）：

```bash
vault write transit/keys/payments/config min_decryption_version=1
```

---

## ✅ 验收

- [ ] 轮转后 `vault read transit/keys/payments` 的 `latest_version = 2`、`keys` 同时含 `1` 与 `2`
- [ ] 新写入的那条记录密文以 `vault:v2:` 开头
- [ ] 旧记录在轮转后、rewrap 前仍可被正常解密
- [ ] `/admin/rewrap` 返回 `{"rewrapped":3,"total":3}`，数据库里所有 `cc_info` 都以 `vault:v2:` 开头
- [ ] 调高 `min_decryption_version=2` 后又调回 `1`，所有 `v2` 密文仍可正常解密

下一步将切换到一个『应用专用 Token』（受策略严格约束），并通过 **吊销该 Token** 验证 `Vault 是这套数据的最终单点开关`——一旦应用失去与 Vault 的认证关系，整条业务读链路立即不可用。
