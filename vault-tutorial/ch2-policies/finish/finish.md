# 恭喜完成实验！🎉

你已经亲手验证了 Vault Policies 文档里五个最关键的设计点：

| 主题 | 一句话总结 |
| --- | --- |
| `-output-policy` 与 capabilities | 任何命令前加 `-output-policy` 自动反推所需 capability；KV 的 put 永远要 create+update |
| 路径优先级 + deny | 多条规则匹中同一路径时取最具体；deny 在它胜出的那次匹配里一票否决 |
| Parameter constraints | `allowed_parameters` 白名单 / `denied_parameters` 黑名单；`required_parameters` 堵默认值绕过；KV v2 完全不支持 |
| Templated policy | `{{identity.entity.id}}` / `aliases.<acc>.name` 让一份 policy 服务全员，按 entity 自动隔离 |
| Password Policy | 跟 ACL Policy 完全无关；`length + rule "charset"`；用 generate 端点调试；rule 越苛刻越慢 |

## 下一步

- **2.7 响应包装（Response Wrapping）**：本节里 `min_wrapping_ttl` 字
  段就是为它准备的——下一节演示一次性密封的 cubbyhole 传递机制
- **2.8 集群 HA**：策略本身是集群级数据，HA 章节会讲它在 Raft 里的复
  制语义
- **第 4 章 机密引擎**：本节的 password policy 在 database / ldap 引
  擎里的实际配置；KV v2 章节会讲怎么用路径分割替代 parameter constraints
- **第 6 章 身份治理**：本节的 templated policy 与 LDAP / OIDC 元数据
  挂钩，后续做更复杂的"按部门 / 按 group claim 分目录"
