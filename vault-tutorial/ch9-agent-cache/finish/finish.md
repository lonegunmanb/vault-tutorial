# 实验完成

恭喜！你已经在终端里亲手验证了 Vault Agent 缓存的全部关键行为：

- 通过 `cache {} + listener {} + use_auto_auth_token = true` 这一最小骨架启用了缓存；
- 同一份动态 IAM 凭据连续两次申请，第二次直接命中 Agent 内存缓存——LocalStack 一侧 IAM User 数量与 Vault 审计日志计数双重佐证；
- 用 `/agent/v1/cache-clear` 按 `type=lease` 精确驱逐缓存条目，第三次申请重新落到 Vault；
- 两次完全相同的 KV 静态机密读取都产生了独立的审计日志条目，证实 Agent 缓存**不**覆盖静态 KV——这种工作流应改用 Vault Proxy。

## 选型回顾

| 场景 | 推荐工具 |
| --- | --- |
| 高频反复申请同一份动态租约（DB / AWS / PKI / SSH） | Vault Agent Caching（本节） |
| 高频反复读同一份静态 KV 机密 | [Vault Proxy 的 static secret caching](/ch5-vault-proxy) |
| 需要在 Vault 故障窗口里继续供给机密、跨多实例共享缓存 | Vault Proxy 或 [Vault Secrets Operator (VSO)](/ch7-vso) |
| 裸机 / VM 环境追求『Agent 重启不丢缓存』 | 现阶段做不到（Persistent cache 仅 `kubernetes` 类型） |

## 接下来可以读

- [9.4 PKI ACME 自动化证书签发](/ch9-pki-acme)（如已发布）
- [5.6 Vault Proxy 入门](/ch5-vault-proxy)
- [7.2 Vault Agent 完整能力面](/ch7-agent)
