# 实验：Transit 机密引擎全流程

[3.13 Transit 机密引擎](/ch3-transit) 把 EaaS 模型、密钥版本化、派生密钥、信封加密、签名 / 验签 / HMAC
的全部机制讲清楚了。本实验把它们串成一条"造钥匙 → 加解密 → 轮转 → 升级密文 → 一刀关旧版 → 信封加密大文件 → 签验"的完整工作流。

---

## 实验环境

后台脚本会自动准备好：

- **Vault 1.19.2** Dev 模式
- **`transit/` 引擎已启用**
- 工具：`jq`、`openssl`（用来本地随机生成测试数据 + 验证 base64）、`xxd`（看二进制密文形状）

---

## 你将亲手验证的事实

1. `vault:v<N>:` 密文格式中的 `<N>` 就是用来加密的密钥版本号
2. `rotate` 后旧密文照常解；新加密自动用新版本；`rewrap` 升级旧密文；`min_decryption_version` 一刀关旧版
3. `derived=true` 的 key 必须传 `context`，不同 context 派生不同子密钥（租户隔离）
4. `datakey/plaintext` 一次返回 (DEK plaintext + DEK ciphertext)，本地加密 100 MB 文件全程毫秒级
5. `ed25519` 签名 + 公钥验证；`hmac` 接口的对称"签名"
6. `deletion_allowed=false` 默认让你 `vault delete` 直接被拒——必须先 `update`

预期耗时：15 ~ 25 分钟。
