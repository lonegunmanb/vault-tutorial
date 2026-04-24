# 恭喜完成实验！🎉

你已经亲手验证了 Vault Identity 文档里五个最关键的设计点：

| 主题 | 一句话总结 |
| --- | --- |
| 隐式 Entity 与 Alias | 任何非 token 的 auth method 一登录就自动建好 entity + alias，无需主动管理 |
| Mount accessor 决定唯一性 | (alias_name, mount_accessor) 才是 alias 的唯一键；同名 alias 在不同 mount 上 Vault 视为不同人 |
| 手工合并 alias | 把多条 alias 改挂到同一个命名 Entity 下，之后任何 mount 登录都共享同一 `entity_id` |
| Entity policy 请求时叠加 | 加权 / 减权立即生效、不需要重登；但 entity policy **只能加**、不能压住 token 自带 policy |
| Group 与子组继承 | policy 沿 entity → group → 父 group 的链路自动传递，最终生效集合是所有层级的并集 |

## 下一步

- **2.6 策略（Policies）**：本节实验里反复出现的 HCL policy 文档，
  下一节会系统讲清 path / capabilities / templated policy / 优先级
- **5.x User Lockout / OIDC / WIF**：本节里 alice 是用最简单的
  userpass 登的——后续身份治理章节会演示如何把 entity 与外部 IdP
  （LDAP / OIDC / WIF）的真实身份系统对接
- **8.x 审计**：本节强调 entity_id 让审计能按真实身份聚合，对应
  审计章节会演示在审计日志里看到 entity_id 字段的样子
