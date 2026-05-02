# 恭喜完成 PKI 机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | 启用 `pki/`、tune `max-lease-ttl` 到 10 年、生成自签 Root CA；`internal` 模式下私钥**不会**出现在响应里 |
| **Step 2** | 启用第二个 `pki_int/` mount、生成 Intermediate CSR、Root 签 CSR、`set-signed` 写回；intermediate 的 issuer = Root |
| **Step 3** | 写一个严格 role，亲手触发 `allowed_domains` / SAN 拒签，并见证 `max_ttl` **截短**而不是报错 |
| **Step 4** | 签出 leaf；用 Root + Intermediate 一起 `openssl verify` 才能 `OK`；缺任意一段都失败 |
| **Step 5** | 单 mount 多 issuer：reissuance 后两张 issuer 共存；切 `default` 决定新签发用哪张；老 leaf 不受影响 |

## 速记图：本实验的 PKI 拓扑

```
                  pki/  (Root mount)
                  ┌────────────────────────┐
                  │ issuer: root-2026      │
                  │   subject: example.com │
                  │   Root  (private key   │
                  │         in Vault)      │
                  └───────────┬────────────┘
                              │ sign-intermediate
                              ▼
              pki_int/  (Intermediate mount)
              ┌──────────────────────────────────┐
              │ issuer: int-2026     ← Step 2    │
              │ issuer: int-2026-v2  ← Step 5.2  │
              │ default: int-2026-v2 ← Step 5.3  │
              └───────────────────┬──────────────┘
                                  │ issue (role: example-dot-com)
                                  ▼
                         leaf: api.example.com
                              (Step 4)
```

## 三个最容易踩的坑

1. **顺序不能乱**：必须先 `intermediate/generate/internal` 拿 CSR，再 `root/sign-intermediate` 让 Root 签，最后 `intermediate/set-signed` 写回。颠倒顺序会报错。

2. **role 的 `max_ttl` 是截短不是拒签**：Step 3.5 演示了请求 720h 但实际签出 72h——如果你期望"超出就失败"，需要在客户端自己校验。

3. **`internal` 私钥永远拿不到原始材料**：Step 1.3 验证了 `private_key` 字段不存在；如果 issuer 私钥丢失（mount 被 disable），证书也就废了——所以企业版才有 Managed Keys（外部 KMS 托管）这条出路。

## 本实验**没有**覆盖（环境限制）

以下来自 [3.X PKI 机密引擎](/ch3-pki) 但不适合在 Killercoda 单机 dev 环境跑的内容，请阅读章节文档了解：

- **完整 ACME 闭环**（HTTP-01 / DNS-01 / TLS-ALPN-01 challenge）—— 需真实可达域名 + DNS 控制权 + 公网端口
- **Performance Replication / Cross-Cluster CRL / Unified CRL** —— Enterprise + 多集群
- **CIEPS / EST / CMPv2 / SCEP** —— Enterprise + 对应客户端
- **完整 root rotation 6 步流程** —— 跨越数月的真实运维操作
- **Managed Keys**（外部 KMS）—— Enterprise + KMS provider

## 与其他章节的关联

- 想看 **policy 怎么写才能让某个角色只能调 `pki_int/issue/<role>` 而不能改 role**：参考 [3.X §6 ACL 设计](/ch3-pki) 与 [2.X 策略](/ch2-policies)。
- **审计**：所有 `pki/` 写操作默认会写审计日志；建议把 `csr`、`certificate`、`common_name`、`alt_names` 等字段从 audit HMAC 中放出，方便排查。

**返回文档**：[3.X PKI 机密引擎](/ch3-pki)
