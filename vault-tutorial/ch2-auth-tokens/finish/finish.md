# 恭喜完成实验！🎉

你已经亲手验证了 Vault Token 文档里五个最关键的设计点：

| 主题 | 一句话总结 |
| --- | --- |
| auth method 是 Token 工厂 | 任何外部认证最终产物都是一条 service token，之后鉴权完全看 token 自身元数据 |
| Token 树与级联撤销 | 父子关系沿 token 树走，撤父节点 → 整棵子树死，配合 `revoke-orphan` 做外科手术 |
| Accessor 单向引用 | 能撤销 / 查属性 / 但拿不到 token 本身——治理权与访问权分离 |
| Periodic vs explicit_max_ttl | periodic 实现"应用活就一直活"，explicit_max_ttl 是无可越过的硬天花板 |
| Service vs Batch | service 重而全功能；batch 轻、可被 standby 节点签发，扛大规模 |

## 下一步

- **2.5 身份实体（Identity Entity）**：Token 之上的"持久身份"层，
  把同一个人通过不同 auth method 登录后产生的多个 token 归并到同一
  实体下做统一治理
- **2.6 策略（Policies）**：Token 上挂的 `policies` 字段到底怎么解析、
  HCL 语法的所有边界
- **5.5 User Lockout**：在本节实验里你已经看到 userpass 是怎么 sign
  token 的，下一步演示如何在 userpass / LDAP / AppRole 上启用暴力破解
  防护
