---
order: 48
title: 4.9 JWT/OIDC 认证：用签名令牌登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.9 JWT/OIDC 认证：用签名令牌登录 Vault

> **核心结论**：`jwt` auth method 是 Vault 中同时承载 JWT 直传登录与 OIDC 浏览器登录的认证插件；前者让调用方把一枚已经由外部系统签名的 JWT 直接交给 Vault 校验，后者让用户通过 OIDC Provider 的浏览器授权流程完成登录。无论采用哪一种模式，Vault 最终签发的仍然是受 Vault policy 约束的 Vault token，而不是把外部 JWT 当作长期 Vault token 使用。

本章先解释 JWT 与 OIDC 两种 role 的边界，再讨论签名校验方式、claim 约束、metadata 映射、OIDC redirect URI 与 Kubernetes ServiceAccount Token 作为 JWT 的特殊用法；配套实验会在 Killercoda 的 Kubernetes kubeadm 单节点环境中，用真实 Kubernetes ServiceAccount Token 登录 Vault 的 `auth/jwt` 挂载点，并观察它与 [4.4 Kubernetes 认证](/ch4-k8s) 的关键差异。

参考：
- [Use JWT/OIDC authentication](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [JWT/OIDC auth method API](https://developer.hashicorp.com/vault/api-docs/auth/jwt)
- [Use Kubernetes for OIDC authentication](https://developer.hashicorp.com/vault/docs/auth/jwt/oidc-providers/kubernetes)
- [Killercoda Creator Documentation](https://killercoda.com/creators)

---

## 1. JWT/OIDC 在 Vault 认证体系里的位置

回到 [4.1 章](ch4-auth-basic.md) 的分类框架，`jwt` auth method 属于“外部签名身份材料换取 Vault token”的认证方式：Vault 不保存调用方的密码，也不主动创建外部身份，而是信任某个外部 issuer 的签名、公钥分发端点或 OIDC Discovery 信息，再把通过验证的声明转换为 Vault Identity alias、metadata 与 policy。

JWT 直传登录适合机器、CI/CD、工作负载或已经拿到 JWT 的客户端：调用方把 `role` 和 `jwt` 提交到 `auth/jwt/login`，Vault 验证签名、有效期、audience、subject 与 bound claims，验证通过后签发 Vault token。

OIDC 登录适合需要浏览器交互的人类用户：Vault 生成指向 OIDC Provider 的授权 URL，用户在 Provider 完成认证，Provider 回调 Vault，Vault 交换并校验 ID Token，最后签发 Vault token；Vault 文档明确说明 CLI 与 UI 都内置了 OIDC 登录流程。

![JWT 直传与 OIDC 浏览器登录对比](/images/ch4-jwt/jwt-vs-oidc-flow.svg)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；左侧画一名自动化流水线工人把写着 JWT 的密封信交给 Vault 门卫，右侧画一名用户跟随浏览器路标走到 OIDC Provider 柜台再回到 Vault；画面标注 JWT login、OIDC Authorization Code Flow、ID Token、Vault token，整体像课程讲义里的温和示意图。

---

## 2. `jwt` role 与 `oidc` role 的边界

同一个 auth method 可以挂载为 `jwt` 或 `oidc` 名称，挂载名只决定路径；真正决定登录流程的是 role 上的 `role_type`，其取值可以是 `jwt` 或 `oidc`，默认值是 `oidc`。

`role_type="jwt"` 的流程较短：Vault 只需要拿到调用方提交的 JWT，并根据挂载级签名校验配置与 role 级约束判断是否接受它；这种模式没有浏览器跳转，也不需要配置 `allowed_redirect_uris`。

`role_type="oidc"` 的流程包含浏览器跳转和回调，因此必须配置 `allowed_redirect_uris`，并且这些 redirect URI 必须同时在 Vault role 与外部 OIDC Provider 侧保持一致；CLI 登录通常使用 `http://localhost:8250/oidc/callback`，Vault UI 登录则使用 `/ui/vault/auth/{path}/oidc/callback` 形式的地址。

从学习顺序看，可以先掌握 `jwt` role，因为它把“签名验证、claim 约束、policy 映射”三件事展现得最直接；再学习 `oidc` role 时，只需要额外理解 redirect URI、authorization code、callback 与 provider client 配置。

---

## 3. 挂载级配置：Vault 如何知道 JWT 可信

JWT/OIDC auth method 必须先启用并配置，用户或机器才可以登录；默认启用方式是 `vault auth enable jwt`，也可以使用 `vault auth enable oidc`，所选名称会成为挂载路径的一部分。

挂载级 `auth/jwt/config` 负责告诉 Vault 如何验证签名；官方 API 文档规定，在同一个挂载点内，`oidc_discovery_url`、`jwks_url`、`jwt_validation_pubkeys` 三者必须且只能配置一种。

OIDC Discovery 让 Vault 从 Provider 的 discovery endpoint 获取签名公钥与 OIDC 元数据；JWKS 让 Vault 从一个 JSON Web Key Set URL 获取公钥；JWKS Pairs 允许配置多个 JWKS URL 并在其中一个成功验证签名时停止；Static Keys 则把 PEM 格式公钥直接存入 Vault 配置。

如果一个组织需要同时信任多个不同 issuer、不同 JWKS endpoint 或不同静态公钥集合，不能把所有方案塞进同一个挂载点；官方文档要求为额外的验证方法启用并配置另一个 backend instance，也就是使用不同挂载路径承载不同信任根。

OIDC role 还需要在挂载级配置 `oidc_discovery_url`、`oidc_client_id` 与 `oidc_client_secret`；如果只做 JWT 直传验证，可以把 OIDC client ID 与 secret 留空，并使用 Discovery、JWKS 或静态公钥完成签名校验。

![JWT 签名验证方式地图](/images/ch4-jwt/jwt-verification-methods.svg)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；画一个 Vault 检票口，前方四条小路分别来自 OIDC Discovery、JWKS URL、JWKS Pairs、Static Public Keys，每条路都送来一把 public key；检票口旁边写 one verification method per mount，远处另有第二个 Vault mount 小亭子表示不同 issuer 需要不同 mount。

---

## 4. Role 约束：从“签名有效”到“允许登录”

签名有效只说明 JWT 确实由可信 issuer 或可信密钥签发，并不等于它可以获得某个 Vault role 的权限；role 级约束负责把“这个令牌是真的”继续收窄为“这个令牌被允许用这个 role 登录”。

`user_claim` 是必填字段，它指定从 JWT 中哪个 claim 取出唯一用户标识；Vault 会用这个值创建成功登录产生的 Identity entity alias，因此该 claim 的值必须是字符串。

从 Vault 1.17 起，如果 JWT 登录请求中的令牌包含 `aud` claim，`jwt` role 上的 `bound_audiences` 必须精确匹配该 JWT 的至少一个 `aud` 值；这不是宽松包含关系，而是登录能否通过的关键条件。

`bound_subject` 用于要求 JWT 的 `sub` claim 等于指定值；`bound_claims` 可以要求任意 claim 具备指定值，期望值可以是字符串、整数、布尔值或字符串列表，且可以通过 `bound_claims_type="glob"` 把字符串解释为 glob 模式。

`groups_claim` 可以指定一个包含字符串列表的 claim，用于创建 Identity group aliases；`claim_mappings` 可以把 JWT 中的 claim 复制到 token metadata 与 alias metadata 中，但被映射的 claim 必须存在，否则认证会失败，且 metadata key `role` 是保留字段。

当 claim 位于嵌套 JSON 对象中时，`user_claim`、`groups_claim`、`bound_claims` 与 `claim_mappings` 都可以使用 JSON Pointer 语法引用嵌套字段，例如 `/groups/primary` 表示读取 `groups.primary`。

---

## 5. JWT 登录的完整数据流

一次 JWT 直传登录可以拆成五步：调用方取得外部系统签发的 JWT；调用方把 `role` 与 `jwt` 提交到 `auth/jwt/login`；Vault 按挂载级配置验证签名与 issuer；Vault 按 role 约束检查 audience、subject、bound claims 与用户标识；Vault 签发带有指定 policies、metadata 与 TTL 的 Vault token。

默认 CLI 调用形式是 `vault write auth/jwt/login role=demo jwt=...`；如果 auth method 被挂载到自定义路径，命令里的 `jwt` 需要替换成实际 mount path。

默认 HTTP API 端点是 `POST /v1/auth/jwt/login`，请求体包含 `role` 与 `jwt`；响应中的 Vault token 位于 `auth.client_token`，后续访问 Vault API 时应使用这枚 Vault token，而不是继续把外部 JWT 当作 Vault token。

这条链路适合说明一个重要边界：Vault 校验的是 JWT 的签名和声明，并不会自动向每一种外部系统回调确认“这个主体此刻是否仍然存在或仍然启用”；是否具备即时撤销能力，取决于所选验证方式和外部系统协议。

---

## 6. OIDC 登录的完整数据流

OIDC 登录不是把用户密码交给 Vault，而是让用户在 OIDC Provider 完成认证，再由 Vault 校验 Provider 返回的 ID Token；官方文档说明 Vault UI 和 CLI 都内置了 OIDC 登录流程，并且 Authorization Code flow 使用 PKCE 扩展。

CLI 登录时，`vault login -method=oidc` 默认使用 `/oidc` 路径；如果 auth method 挂载在其他路径，需要通过 `-path` 指定。CLI 会启动本地 callback listener，默认端口为 8250，也可以通过 `port`、`callbackhost`、`callbackmethod` 等参数调整。

OIDC 配置最常见的错误是 redirect URI 不完全一致；官方排障建议逐项检查协议、主机名、端口、`localhost` 与 `127.0.0.1` 的差异以及尾部斜杠，因为 Vault 与 Provider 两侧必须精确匹配。

OIDC role 的 `bound_audiences` 通常不是必需项，因为 OIDC Provider 会把 client ID 用作 audience，OIDC 验证本身会处理这一点；官方排障建议先只配置必需的 `user_claim` 跑通登录，再逐步增加 bound claims、metadata 映射与 scopes。

`verbose_oidc_logging` 可以在 Vault server debug 日志中记录收到的 OIDC token 与 claims，便于调试 claim 名称与结构；但官方明确提醒这些日志可能包含敏感信息，不应在生产环境启用。

---

## 7. Kubernetes ServiceAccount Token 作为 JWT

Kubernetes 可以充当 OIDC Provider，使 Vault 通过 JWT/OIDC auth method 校验 Kubernetes ServiceAccount Token；这条路径与 [4.4 Kubernetes 认证](/ch4-k8s) 的核心区别在于，JWT auth 不调用 Kubernetes TokenReview API，而是用公钥密码学验证 JWT 内容。

由于 JWT auth 不调用 TokenReview，已经被 Kubernetes 撤销的 token 在过期前仍可能被 Vault 视为有效；官方建议用较短 TTL 的 ServiceAccount Token 缓解风险，或者在需要提前撤销语义时改用会调用 TokenReview API 的 Kubernetes auth method。

如果 Kubernetes 集群启用了 ServiceAccountIssuerDiscovery，且 kube-apiserver 的 `--service-account-issuer` 是 Vault 可访问的 URL，最直接的做法是把 JWT auth mount 配置为使用 `oidc_discovery_url`；该特性从 Kubernetes 1.18 存在，并从 1.20 起默认启用，而 Pod 中挂载的 token 从 Kubernetes 1.21 起默认是短生命期 token。

如果 Vault 不能访问 Kubernetes API 或 discovery endpoint，也可以使用 `jwt_validation_pubkeys` 配置 Kubernetes 的 ServiceAccount 签名公钥；官方文档说明，如果能在控制平面节点直接读取 `/etc/kubernetes/pki/sa.pub`，这份文件已经是 PEM 格式，可以跳过从 JWKS 转换为 PEM 的步骤。

为 Kubernetes ServiceAccount Token 创建 JWT role 时，官方示例使用 `role_type="jwt"`、`user_claim="sub"`、`bound_subject="system:serviceaccount:<namespace>:<serviceaccount>"`、`bound_audiences=<token audience>` 与合适的 policy/TTL；登录时可把 Pod 默认 token 文件或 TokenRequest 生成的 token 提交给 `auth/jwt/login`。

如果需要控制 ServiceAccount Token 的 audience 与 TTL，可以使用 projected `serviceAccountToken` volume；官方示例中 `audience: vault` 要与 JWT role 的 `bound_audiences=vault` 对应，`expirationSeconds: 600` 表示 10 分钟，这是示例中给出的最小 TTL。

![Kubernetes JWT auth 不经过 TokenReview 的边界](/images/ch4-jwt/kubernetes-oidc-without-tokenreview.svg)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；画一个 Kubernetes ServiceAccount Token 像一张有到期时间的火车票，Vault 站务员只用 public key 放大镜检查签名、aud、sub、exp；旁边画一扇写着 TokenReview API 的门没有被打开；远处有一块提示牌写 short TTL or Kubernetes auth for revocation。

---

## 8. 生产配置时的安全边界

JWT/OIDC auth method 的安全性首先取决于 issuer 与公钥来源是否可信；不要把同一挂载点同时承担多个不相关 issuer 的验证责任，遇到多个信任根时应使用不同 mount path 隔离配置。

JWT role 应尽量显式设置 `bound_audiences`、`bound_subject` 或 `bound_claims`，避免“任何由该 issuer 签名的 token 都可以登录同一个 role”；官方 API 文档也要求 role 必须设置至少一个 bound value。

JWT 中的 `aud` 应被视作“这枚 token 原本打算交给谁”的边界；从 Vault 1.17 起，带 `aud` 的 JWT 必须与 `jwt` role 的 `bound_audiences` 精确匹配至少一个值，这一规则可以降低 token 被跨系统误用的概率。

对 Kubernetes ServiceAccount Token 使用 JWT auth 时，应优先使用短生命期 token 和明确 audience；如果组织要求删除 ServiceAccount 或 Pod 后立即失效，应使用 Kubernetes auth method，因为它会调用 TokenReview API，而不是仅凭本地签名验证接受未过期 token。

OIDC 排障可以短期开启更详细日志，但不要在生产中开启 `verbose_oidc_logging`；官方提醒它会把收到的 token 与 claim 数据写入 server 日志，而这些内容可能包含敏感信息。

---

## 9. 常用 CLI/API 速记

启用默认 JWT 挂载点可以使用 `vault auth enable jwt`；如果团队希望把人类 OIDC 登录挂到更直观的路径，也可以使用 `vault auth enable oidc`，后续命令中的路径应与实际 mount path 保持一致。

配置 JWT 直传验证时，需要在 `auth/jwt/config` 写入一种签名验证来源，例如 `oidc_discovery_url`、`jwks_url` 或 `jwt_validation_pubkeys`；同一挂载点不能同时配置多个验证来源。

创建 role 的 API 路径是 `POST /auth/jwt/role/:name`，读取、列出、删除 role 分别使用 `GET /auth/jwt/role/:name`、`LIST /auth/jwt/role` 与 `DELETE /auth/jwt/role/:name`。

JWT 登录的 API 路径是 `POST /auth/jwt/login`，请求体中 `jwt` 必填，`role` 可省略但只有在挂载级配置了 `default_role` 时才有意义；成功响应中的 `auth.client_token` 是后续访问 Vault 的凭据。

OIDC 低层 API 包含 `POST /auth/jwt/oidc/auth_url` 与 `GET /auth/jwt/oidc/callback`：前者生成授权 URL，后者用 provider 返回的 authorization code 换取并验证 ID Token，然后返回 Vault token。

---

## 10. 与第 7 章高级身份治理的关系

本章的重点是把 JWT/OIDC auth method 作为第 4 章认证方法体系的一员讲清楚：如何挂载、如何验证签名、如何写 role、如何让 Kubernetes ServiceAccount Token 作为 JWT 登录 Vault。

第 7 章可以继续展开更复杂的身份治理：接入 Keycloak 或 Dex 跑完整 OIDC Authorization Code Flow、处理 groups claim、把 Vault Identity Group 与外部组映射起来，以及把 Vault 自身作为 OIDC Provider 给下游应用提供 SSO。

这种拆分的原因是教学边界不同：第 4 章要先让学员理解“认证方法如何把外部身份换成 Vault token”，第 7 章再讨论“组织级身份联邦和组治理如何落地”。

---

## 11. 本章动手实验

本章实验使用 Killercoda 的 `kubernetes-kubeadm-1node` 后端环境，在真实 Kubernetes API server 与 kubeadm 控制平面节点上完成 JWT auth：先观察 ServiceAccount Token 的 issuer、audience、subject 与过期时间，再把 Kubernetes ServiceAccount 签名公钥配置到 Vault `auth/jwt/config`，创建只允许 `demo/jwt-app` 登录的 role，最后删除 ServiceAccount 并验证 JWT auth 在 token 过期前仍可凭签名接受该 token。

实验目标不是替代 [4.4 Kubernetes 认证](/ch4-k8s)，而是帮助学员亲自比较两条路线：`auth/kubernetes` 通过 TokenReview 获得更强的即时有效性检查，`auth/jwt` 则通过签名公钥与 claim 约束获得更轻量的离线验证能力。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-jwt" title="实验：JWT/OIDC 认证完整动手——Kubernetes ServiceAccount Token、签名公钥、audience 约束与撤销边界" />

---

## 参考文档

- [Use JWT/OIDC authentication](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [JWT/OIDC auth method API](https://developer.hashicorp.com/vault/api-docs/auth/jwt)
- [Use Kubernetes for OIDC authentication](https://developer.hashicorp.com/vault/docs/auth/jwt/oidc-providers/kubernetes)
- [Killercoda Creator Documentation](https://killercoda.com/creators)
