# 恭喜完成实验！🎉

你已经在一个真实的 Vault 服务器上完整执行了**机密引擎迁移**和**认证方法迁移**，亲手验证了 Mount Migration 的原子性和数据完整性。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **查看 Accessor** | 每个挂载点有唯一 Accessor，迁移前后不变——证明是"搬家"不是"新建" |
| **secrets move** | `legacy-kv/` → `archive/`，数据零拷贝、瞬间完成 |
| **auth move** | `old-login/` → `corp-userpass/`，用户、密码、Policy 绑定全部保留 |
| **Policy 不自动更新** | 迁移后旧路径的 Policy 会导致 403，必须手动修复 |
| **secrets move（主路径）** | `secret/` → `kv-prod/`，验证了大规模迁移的可行性 |
| **生产检查清单** | 审计 Policy → 计划窗口 → 执行 move → 更新 Policy → 更新应用 → 验证 |

## 关键概念

```
┌─────────────────────────────────────────────────────────────┐
│  vault secrets move / vault auth move                       │
│  ─ 底层 API：POST /sys/remount                             │
│  ─ 本质：修改内部路由表的路径映射（不复制数据）             │
│  ─ 证据：Accessor 迁移前后不变                              │
│  ─ 异步执行：小引擎毫秒级，大引擎可通过 migration_id 监控  │
│  ─ 权限要求：需要 sys/remount 的 sudo 能力                 │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  迁移不会做的事                                              │
│  ─ ❌ 不自动修改 Policy 中的路径                            │
│  ─ ❌ 不保留活跃的动态 Lease                                │
│  ─ ❌ 不跨引擎类型转换（KV → Transit）                     │
│  ─ ❌ 不覆盖已有挂载点                                     │
└─────────────────────────────────────────────────────────────┘
```

## 下一步

- 下一节将学习 CLI 的全面操作，包括 `vault secrets` 和 `vault auth` 的完整生命周期管理
- 如果你在生产环境中有大规模引擎需要迁移，参考 [官方文档：Mount Migration](https://developer.hashicorp.com/vault/docs/concepts/mount-migration) 了解 `sys/remount/status` 的详细监控方式
