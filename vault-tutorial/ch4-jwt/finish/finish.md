# 恭喜完成 JWT/OIDC 认证实验！

这一节你使用真实 Kubernetes ServiceAccount Token 跑通了 Vault JWT auth 的完整流程。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| ServiceAccount Token | Kubernetes TokenRequest 可以签发带 audience、subject、issuer 与过期时间的 JWT |
| `auth/jwt/config` | Vault 可以使用 Kubernetes ServiceAccount 签名公钥验证 JWT 签名 |
| JWT role | `bound_audiences` 与 `bound_subject` 会把“签名有效”收窄为“允许用这个 role 登录” |
| 登录响应 | JWT 登录成功后得到的是 Vault token，权限由 Vault policy 决定 |
| 错误 audience/subject | 签名正确但 claim 不满足 role 约束时，登录会失败 |
| 撤销边界 | JWT auth 不调用 TokenReview，因此删除 ServiceAccount 后，未过期的旧 JWT 仍可能被接受 |

## 一张图总结本章

```text
Kubernetes ServiceAccount Token
        |
        |  signed JWT: iss / sub / aud / exp
        v
auth/jwt/login  -- role + jwt -->  Vault
        |                                  |
        |                                  | public key verification
        |                                  v
        |                          jwt_validation_pubkeys
        v
JWT role constraints:
  bound_issuer
  bound_audiences
  bound_subject
  bound_claims / claim_mappings
  policies / ttl
        |
        v
Vault token
```

本图的主线是：JWT auth 不把 Kubernetes API server 当作在线裁判，而是把签名公钥、issuer、audience、subject 与 Vault policy 组合成认证边界。

## 回到正文

回到 [4.9 章正文](/ch4-jwt) 后，建议重点复查 §3 的签名验证来源、§4 的 role 约束、§7 的 Kubernetes ServiceAccount Token 差异与 §8 的生产安全边界。