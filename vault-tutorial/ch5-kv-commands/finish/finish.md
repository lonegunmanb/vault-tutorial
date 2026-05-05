# 恭喜完成实验！

学员已经在真实 Vault dev server 上完成了 KV 专用命令的核心练习。

## 本实验的核心收获

| 阶段 | 已验证的事实 |
| :--- | :--- |
| `-mount` | 挂载点与机密路径应分开表达，KV v2 会自动映射到真实 API 路径 |
| `enable-versioning` | 已存在的 KV v1 挂载点可以启用版本控制 |
| `put` / `get` / `list` | KV v2 每次写入产生版本，读取可指定版本，列表只显示 key 名称 |
| `metadata` | key 级 metadata 可以控制保留版本数、CAS 要求和自定义 metadata |
| CAS / `patch` | CAS 要求写入前确认版本，`patch` 适合合并少量字段 |
| 删除三态 | `delete` 可恢复，`destroy` 销毁指定版本，`metadata delete` 清除全部版本和 metadata |
| `rollback` | 旧版本会被复制成新的当前版本，版本号不会倒退 |

## 关键心智模型

```text
KV 挂载点 secret/
        ↓
vault kv 子命令理解 KV v1 / KV v2 的差异
        ↓
KV v2 自动映射 data、metadata、delete、undelete、destroy 等内部路径
        ↓
版本号、删除状态、metadata 共同决定读写结果
```

后续学习策略与生产接入时，请继续保持这个区分：应用和 CLI 可以使用较友好的 KV 命令；Policy 和 HTTP API 仍需要理解 KV v2 的真实路径结构。