# 恭喜完成实验！

你已经完成了 `vault login`、`vault auth` 与 `vault token` 三组命令的核心练习。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| `auth enable/list/help/tune` | 认证方法是挂载在路径上的登录入口，可以独立启用、查看与调优 |
| `login` | 登录命令把外部凭据换成 Vault token，`-path` 指向实际挂载路径 |
| `token create/lookup/capabilities` | token 可以被显式创建、查询状态，并诊断它对某条路径的能力 |
| `token renew/revoke` | token 生命周期可以延长，也可以用 token 值或 accessor 终止 |
| `auth disable` | 禁用认证方法会使入口失效，并撤销通过该方法签发的 token |

## 关键心智模型

```text
vault auth ...   管理“登录入口”
vault login      使用“登录入口”换取 token
vault token ...  管理“已经签发出去的 token”
```

后续学习 LDAP、Kubernetes、OIDC、TLS Cert 或云平台 IAM 认证方法时，可以反复套用这个模型：先启用并配置 auth method，再通过 login 获取 token，最后用 token 命令观察和管理生命周期。
