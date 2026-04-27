# 恭喜完成 Transit 机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | `vault:v1:` 密文格式；GCM nonce 随机让同明文 → 不同密文；批量接口 |
| **Step 2** | rotate 增版本而非替换；旧密文照常解；rewrap 升级旧密文无需明文；min_decryption_version 一刀关旧版（且可逆） |
| **Step 3** | derived 派生密钥实现租户隔离；信封加密让 100 MB 数据从不经过 Vault |
| **Step 4** | ed25519 非对称签名 + 公钥分发；HMAC 对称签名；deletion_allowed 双保险 + 删 key 不可逆 |

## EaaS 心智速记

```
                  KV 引擎                   Transit 引擎
            (Vault keeps SECRETS)      (Vault keeps KEYS)
                    │                          │
   App 拿              路径 + Token          密文 + Token
   Vault 还            机密本身              明文 / 公钥 / 验签结果
   业务数据存哪        Vault Storage         App 自己的数据库
   撤销访问的方式      改 Policy             改 Policy 或删整把 key
```

## 三个最容易踩的坑

1. **`plaintext` 必须 base64** —— 直接传字符串会被当成已编码字符。

2. **rotate 后忘记 rewrap，再后来 raise min_decryption_version 全线失败** ——
   生产规范：rotate → 排程异步 rewrap → 几个保留周期后才 raise min。

3. **删 key 不是"撤销访问"的良好选项** —— 不可逆且会让所有密文成废比特。
   日常撤销请用 Policy/Token；只有在合规要求"销毁数据"时才删 key。

## 与下一节的衔接

- 本节 (3.13) 与上节 [3.12 TOTP](/ch3-totp) 共同构成 Vault 的"密码学即服务"双子星
- 与 [3.2 KV v2](/ch3-kv-v2) 互为镜像
- 与 [2.7 Response Wrapping](/ch2-response-wrapping) 一起，构成 Vault 的"机密物流"完整体系：
  Transit 让数据加密后能在任意路径上流转，Wrapping 让 Token 包装后能一次性投递

**返回文档**：[3.13 Transit 机密引擎](/ch3-transit)

---

> 第 3 章 (Secret Engines) 至此告一段落。后续章节将转入第 4 章及之后的认证体系、企业管理、运维主题。
