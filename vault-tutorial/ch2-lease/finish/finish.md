# 恭喜完成实验！🎉

你已经亲手验证了 Vault 租约机制里**最反直觉、也最实用**的几条设计：

| 边界条件 | 一句话总结 |
| --- | --- |
| `lease_id` 前缀结构 | 路径前缀 + 唯一后缀，支撑 `sys/leases` 树状组织与前缀撤销 |
| `max_lease_ttl` | 任何续约都越不过去的硬天花板——爆炸半径上限 |
| `increment` 语义 | 不是"在当前 TTL 后追加"，而是"从现在重新算"——应用可主动缩短 |
| Token 级联撤销 | 父 Token revoke → 该 Token 签出的所有目标系统账号自动清理 |
| `-prefix` 前缀撤销 | 一句话按路径前缀批量回收，事故响应核武器 |

## 下一步

- **2.4 认证（Authentication）与 Token 树状层级**：第 4 步级联撤销
  能成立的底层数据结构
- **3.x CLI 高级管理**：`operator` / `policy` / `lease` 子命令的完整谱系
- **5.5 User Lockout**：暴力破解防御与 lease/token 的协同
