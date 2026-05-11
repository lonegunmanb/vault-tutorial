# 恭喜完成 EaaS Gin 应用实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | 应用从不保管业务密钥；写入接口把 `cc_info` 送给 `transit/encrypt/payments`、只把 `vault:v1:...` 密文写入 `payments` 表的 `cc_info` 列；`SELECT ... LIKE '%4242%'` 在数据库里搜不到任何明文卡号；`GET /payments` 反向调用 `transit/decrypt` 还原明文 |
| **Step 2** | `rotate` 在密钥下追加 `v2`；新写入自动用 `v2`；旧 `v1` 密文仍可解；`/admin/rewrap` 在 Vault 内部完成『解密 + 重新加密』，应用与运维都看不到明文；`min_decryption_version` 可一刀关旧版 |
| **Step 3** | 用最小权限策略 `eaas-app` 给应用发一个专用 Token；吊销该 Token 后，业务读接口立即返回 `502`、内部夹带 Vault 的 `403 permission denied`；换一个新 Token、应用立即恢复，业务数据库本身从未被触碰 |

## 与官方 Spring Cloud 演示的对照

本节 Gin 应用与 [hashicorp-education/learn-vault-spring-cloud](https://github.com/hashicorp-education/learn-vault-spring-cloud) 的 `vault-transit/` 子项目在外部行为上完全一致：

| 维度 | 官方 Java 版本 | 本节 Go + Gin 版本 |
| --- | --- | --- |
| 写入端点 | `POST /payments` | `POST /payments` |
| 读取端点 | `GET /payments` | `GET /payments` |
| 加密字段 | `cc_info` | `cc_info` |
| 数据库 | PostgreSQL 16，表 `payments(id, name, cc_info, created_at)` | 完全相同（沿用官方 [`schema.sql`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/resources/schema.sql)） |
| Vault 密钥名 | `payments` | `payments` |
| POST 返回值 | 包含刚插入这一条的数组、`cc_info` 是密文 | 完全相同 |
| 与 Vault 通信 | Spring Cloud Vault SDK | 直接 `net/http` 调 REST API |

## EaaS 心智速记

```
┌──────────────────────┐  POST /payments  (含 cc_info 明文)
│   Web / 移动端 / 调用方  │ ─────────────────────────────►
└──────────────────────┘
                                      │
                                      ▼
                          ┌──────────────────────┐
                          │ Gin Web 应用 (本机)   │
                          │   - 不存任何密钥       │
                          │   - 只持 VAULT_TOKEN   │
                          └──────────────────────┘
                              │                ▲
                  encrypt(明文)│                │decrypt(密文) → 明文
                              ▼                │
                          ┌──────────────────────┐
                          │  Vault transit/payments  │
                          │  (持密钥，不存业务数据)  │
                          └──────────────────────┘
                              │
                              ▼
                          ┌──────────────────────┐
                          │  PostgreSQL payments 表  │
                          │  cc_info 列只有 vault:vN: │
                          └──────────────────────┘
```

## 把这套思路放回真实工程

- **数据库换成什么都行**：本实验沿用官方仓库选用的 PostgreSQL 16；把 `database/sql` 客户端换成 MySQL / MongoDB / S3 的客户端，整条 EaaS 闭环不需要改动一行 Vault 调用代码。
- **延迟与可用性的权衡**：每次读写都同步访问 Vault 会引入一次额外的网络往返。生产中常见做法是给应用前面加一个 [Vault Proxy](/ch5-vault-proxy)（5.6 节）做请求级响应缓存，或者用[信封加密（DEK）](/ch3-transit) 把『大对象的对称加密』放在应用本地、只让 Vault 加解密那把短短的数据密钥。
- **Token 不要硬编码**：本实验为了演示明确性，把 `VAULT_TOKEN` 直接写在了启动命令里。生产中应当用 [Vault Agent](/ch7-agent) 或 [Vault Secrets Operator](/ch7-vso) 之类的机制让应用『按身份自动换 Token』，而不是手动注入。
- **审计与速率限流是这套方案的兜底**：[8 章](/ch8-audit-overview) 的审计日志能追踪每一次 `transit/encrypt` 与 `transit/decrypt` 的调用主体；[9.1 节](/ch9-production-hardening) 的速率限流可以挡住突发的暴力解密尝试。

## 清理

实验环境会随 Killercoda 容器一起销毁，无需手动清理；如果想在课堂上重置：

```bash
pkill -x app 2>/dev/null
psql -c 'TRUNCATE payments;'
vault delete transit/keys/payments    # 后台 init 已把 deletion_allowed 设为 true
```
