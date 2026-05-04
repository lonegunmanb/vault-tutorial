# 恭喜完成 Kubernetes 认证实验！

这一节你在真实 kubeadm 单节点集群上配置了 Vault Kubernetes auth method，并让 ServiceAccount JWT 通过 Kubernetes TokenReview 转换成 Vault token。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuring kubernetes；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| `auth/kubernetes/config` | Vault 需要 Kubernetes API server 地址、CA 证书与 reviewer JWT 才能调用 TokenReview |
| reviewer RBAC | reviewer ServiceAccount 需要 `system:auth-delegator` 才能访问 TokenReview API |
| `myapp` 登录 | `demo/myapp` 的 ServiceAccount JWT 可以换取 Vault token |
| role 约束 | ServiceAccount 名称、namespace、namespace selector 与 audience 都会影响登录是否通过 |
| token metadata | 登录响应会带上 ServiceAccount 名称、namespace 与 UID 等 metadata |
| annotation metadata | `vault.hashicorp.com/alias-metadata-*` 注解可以进入 Vault alias metadata |
| templated policy | Vault policy 可以引用 alias metadata 渲染工作负载专属 secret 路径 |

这些结论对应 HashiCorp 文档中的配置、登录、role 参数与 templated policy 工作流。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuration；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Create/Update role；HashiCorp Vault 文档《Kubernetes auth method》§Workflows / Working with templated policies]

## 一张图总结本章

```text
Pod / ServiceAccount
        |
        |  Kubernetes ServiceAccount JWT
        v
auth/kubernetes/login  -- role + jwt -->  Vault
        |                                  |
        |                                  | TokenReview
        |                                  v
        |                          Kubernetes API server
        |                                  |
        |                          authenticated user / uid / audience
        v
Vault role constraints:
  bound_service_account_names
  bound_service_account_namespaces
  bound_service_account_namespace_selector
  audience
  token_policies / templated policy
        |
        v
Vault token
```

本图的主线是：Kubernetes 负责证明 JWT 是否属于某个仍然有效的 ServiceAccount，Vault 负责把该身份映射到自身 policy 与 token 生命周期。 [来源：HashiCorp Vault 文档《Kubernetes auth method》§Configuring kubernetes；HashiCorp Vault API 文档《Kubernetes auth method (API)》§Login]

## 回到正文

回到 [4.4 章正文](/ch4-k8s) 后，建议重点复查 §5 的 role 约束、§8 的短生命期 token 策略、§10 的 annotation alias metadata 与 templated policy；这三处是生产落地时最容易影响权限边界的配置点。 [来源：HashiCorp Vault API 文档《Kubernetes auth method (API)》§Create/Update role；HashiCorp Vault 文档《Kubernetes auth method》§How to work with short-lived Kubernetes tokens；HashiCorp Vault 文档《Kubernetes auth method》§Workflows / Working with templated policies]
