---
order: 57
title: 5.7 底层引擎挂载点无损热迁移（Mount Migration）技术剖析
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.7 底层引擎挂载点无损热迁移（Mount Migration）技术剖析

> **核心结论**：`vault secrets move` / `vault auth move`（底层 API
> `POST /sys/remount`）能把一个机密引擎或认证方法连同其所有数据、角色、
> 配置，**原子地从旧路径迁移到新路径**。Vault 内部只修改路由表的映射关
> 系——不复制数据，迁移前后 Accessor 不变。但 **Policy 不会自动更新**，
> 活跃的动态 Lease 也会失效。

参考：
- [Mount Migration — Concepts](https://developer.hashicorp.com/vault/docs/concepts/mount-migration)
- [/sys/remount — API](https://developer.hashicorp.com/vault/api-docs/system/remount)
- [vault secrets move — CLI](https://developer.hashicorp.com/vault/docs/commands/secrets/move)
- [vault auth move — CLI](https://developer.hashicorp.com/vault/docs/commands/auth/move)

---

## 1. 为什么需要 Mount Migration

在生产环境中，挂载路径会因为各种原因需要变更：

| 场景 | 例子 |
| --- | --- |
| **命名规范统一** | 早期用默认路径 `secret/`，后来规范要求 `kv-prod/` |
| **团队拆分** | 一个 `secret/` 下混着多个团队的数据，要按团队拆到独立路径 |
| **遗留系统下线** | `legacy-kv/` 还有数据没迁完，想换一个更清晰的路径名 |
| **认证方法整理** | `old-login/` 太含糊，想重命名为 `corp-userpass/` |

在 Vault 1.10 之前，路径变更意味着**手动导出-导入**：

1. 写脚本遍历旧路径，逐条读取明文数据
2. 在新路径启用同类型引擎
3. 逐条写入新路径
4. 手动重建所有角色（AppRole role、Database connection 等）
5. 发现还有 Policy 引用了旧路径……
6. 最后才敢 `vault secrets disable` 旧路径

全程耗时长、数据丢失风险大、角色/配置无法简单导出。

---

## 2. 底层机制：路由表指针重定向

Vault 内部维护一张**路由表**，把 API 路径前缀映射到后端引擎实例。每个
引擎实例有一个不可变的唯一标识——**Accessor**。

```
路由表（迁移前）                路由表（迁移后）
┌──────────────┬──────┐       ┌──────────────┬──────┐
│ 路径前缀      │ 引擎  │       │ 路径前缀      │ 引擎  │
├──────────────┼──────┤       ├──────────────┼──────┤
│ legacy-kv/   │ A-123 │  ──→  │ archive/     │ A-123 │  ← 同一个引擎
│ secret/      │ B-456 │       │ secret/      │ B-456 │
│ userpass/    │ C-789 │       │ userpass/    │ C-789 │
└──────────────┴──────┘       └──────────────┴──────┘
```

`sys/remount` 的本质是：**把 Accessor A-123 在路由表中的键从
`legacy-kv/` 改成 `archive/`**。底层存储中的加密数据块一个字节都没动
过——这就是为什么迁移几乎是瞬间完成的。

**证据**：迁移前后查看 `vault secrets list -detailed`，目标引擎的
`Accessor` 和 `UUID` 完全相同。

---

## 3. CLI 用法

### 3.1 机密引擎迁移

```bash
vault secrets move <source> <destination>
```

```bash
# 例：把 legacy-kv/ 搬到 archive/
vault secrets move legacy-kv/ archive/
```

### 3.2 认证方法迁移

```bash
vault auth move <source> <destination>
```

```bash
# 例：把 old-login/ 搬到 corp-userpass/
vault auth move old-login/ corp-userpass/
```

两个命令底层都调用 `POST /sys/remount`：

```json
{
  "from": "legacy-kv/",
  "to": "archive/"
}
```

### 3.3 迁移状态查询

`sys/remount` 返回一个 `migration_id`。对于小引擎，迁移在返回响应前
就已经完成；对于 TB 级大引擎，可以通过该 ID 轮询状态：

```bash
vault read sys/remount/status/<migration_id>
```

---

## 4. 迁移保留什么、不保留什么

### 4.1 完整保留的内容

| 内容 | 说明 |
| --- | --- |
| **所有加密数据** | KV 的每一条 key-value、每个历史版本 |
| **引擎配置** | `default_lease_ttl`、`max_lease_ttl` 等 tune 参数 |
| **角色/连接** | Database 引擎的 connection、role；AppRole 的 role；PKI 的 role |
| **Accessor / UUID** | 引擎的唯一标识不变——证明是"搬家"不是"新建" |

### 4.2 不会自动处理的内容

| 内容 | 影响 | 处理方式 |
| --- | --- | --- |
| **Policy 中的路径** | 引用旧路径的 Policy 会导致 403 | 手动更新 Policy |
| **活跃的动态 Lease** | Database 等引擎签发的临时凭据无法续期/撤销 | 迁移前确保 Lease 已到期或手动撤销 |
| **应用代码中的路径** | 应用请求旧路径会 404 | 更新应用配置或 Agent 模板 |
| **审计日志中的旧路径** | 历史日志不会被修改 | 无需处理，审计日志会记录 remount 事件 |

> **这是设计上的有意选择**：Policy 属于独立的管理域，Vault 不假设管理
> 员希望所有引用旧路径的 Policy 都自动跟着变。这避免了在复杂的多团队
> 环境中产生意料之外的权限变更。

---

## 5. 限制条件

| 限制 | 说明 |
| --- | --- |
| **不能跨类型** | 不能借 move 把 KV v1 变成 KV v2，或把 KV 变成 Transit |
| **不能覆盖已有挂载** | 目标路径如果已经有引擎挂载，Vault 拒绝操作 |
| **迁移期间引擎不可用** | 从 move 命令发出到完成的短暂窗口内，新旧路径都不可用 |
| **需要 sudo 权限** | 操作者的 Token 必须对 `sys/remount` 路径有 `sudo` 能力 |
| **命名空间限制** | 开源版不涉及；企业版中跨命名空间迁移有额外限制 |

---

## 6. 生产环境迁移检查清单

```
  迁移前准备                         迁移执行                         迁移后验证
  ──────────                         ────────                         ──────────
  ① 审计所有引用旧路径的 Policy      ④ vault secrets move old/ new/   ⑥ 从新路径读取数据
  ② 搜索应用代码/CI 中的旧路径       ⑤ 确认 migration 完成            ⑦ 更新 Policy
  ③ 确认无活跃动态 Lease                                              ⑧ 更新应用配置
     或手动 revoke                                                    ⑨ 用受影响身份测试读写
```

### 6.1 快速发现引用旧路径的 Policy

```bash
# 列出所有 policy 并搜索旧路径
for p in $(vault policy list); do
  if vault policy read "$p" | grep -q "legacy-kv/"; then
    echo "⚠️  Policy '$p' 引用了旧路径 legacy-kv/"
  fi
done
```

### 6.2 验证 Accessor 不变

```bash
# 迁移前
BEFORE=$(vault secrets list -format=json | jq -r '.["legacy-kv/"].accessor')

vault secrets move legacy-kv/ archive/

# 迁移后
AFTER=$(vault secrets list -format=json | jq -r '.["archive/"].accessor')

[ "$BEFORE" = "$AFTER" ] && echo "✅ 同一个引擎" || echo "❌ 异常"
```

---

## 7. 与其他 Vault 操作的对比

| 操作 | 作用 | 数据影响 |
| --- | --- | --- |
| `vault secrets move` | 修改挂载路径 | 零——数据原封不动 |
| `vault secrets disable` | 卸载引擎 | **彻底销毁**该引擎下所有数据 |
| `vault secrets tune` | 修改引擎运行参数 | 零——只改 TTL 等配置 |
| `vault secrets enable` | 在新路径创建全新引擎 | 不涉及旧数据 |

**关键区别**：`move` 是唯一一个在不丢失数据的前提下改变路径的方式。
`disable` + `enable` 会导致数据永久丢失。

---

## 8. 互动实验

本节配套了一个完整的 Killercoda 实验：

- **Step 1**：理解挂载点的 Accessor 模型
- **Step 2**：执行 `vault secrets move`，验证 KV 数据完整迁移、Accessor 不变
- **Step 3**：执行 `vault auth move`，验证用户数据和登录功能完整保留
- **Step 4**：演示 Policy 断裂与修复——迁移后旧路径 Policy 导致 403，
  手动更新后恢复

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-mount-migration" title="实验：挂载点无损热迁移（vault secrets move / auth move）" />
