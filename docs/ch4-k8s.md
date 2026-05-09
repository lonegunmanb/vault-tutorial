---
order: 43
title: 4.4 Kubernetes 认证：让 Pod 用 ServiceAccount 身份登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.4 Kubernetes 认证：让 Pod 用 ServiceAccount 身份登录 Vault

> **核心结论**：Kubernetes 认证方法（`kubernetes`）让运行在 Kubernetes 中的工作负载使用自己的 ServiceAccount Token 登录 Vault，并由 Vault 签发一个受 Vault policy 约束的 Vault token；它的验证核心不是让 Vault 自己离线猜测 JWT 是否可信，而是让 Vault 调用 Kubernetes 的 TokenReview API 确认该 ServiceAccount Token 仍然有效、属于哪个 ServiceAccount、是否满足指定 role 的约束。

参考：
- [Kubernetes Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes Auth API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [Kubernetes Service Accounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
- [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
- [Killercoda Creator Documentation](https://killercoda.com/creators)

---

## 1. Kubernetes 认证在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 的分类框架，Kubernetes 认证方法属于“平台/工作负载身份型”认证：调用者通常不是人，而是一个运行中的 Pod；Pod 携带 Kubernetes 为其 ServiceAccount 签发或挂载的 JWT，Vault 通过 Kubernetes API 验证该 JWT，再把它转换成 Vault 自己的 token。

ServiceAccount 是 Kubernetes 中面向非人类主体的账号类型，它为 Pod、系统组件或集群内外的自动化程序提供可被 Kubernetes API 识别的身份；与人类用户账号不同，ServiceAccount 是 Kubernetes API 中的对象，并且天然属于某个 namespace。

本章讨论的是“Pod 登录 Vault”的入站方向：JWT 从 Pod 流向 Vault，Vault 再签发 Vault token；这与第 3 章 Kubernetes 机密引擎“Vault 主动向 Kubernetes 申请 ServiceAccount Token”的出站方向相反，二者都使用 Kubernetes 身份材料，但信任方向与使用场景完全不同。

---

## 2. 基本术语：ServiceAccount Token、JWT、TokenReview

ServiceAccount Token 是 Kubernetes 为 ServiceAccount 生成的签名 JWT；JWT（JSON Web Token）是一种把声明、签名和有效期等信息编码在字符串中的令牌格式，Kubernetes 会在服务账号认证流程中检查签名、过期时间、对象引用、当前有效性以及 audience 等声明。

TokenReview 是 Kubernetes 暴露的认证检查 API，它接收一个 bearer token，并尝试把该 token 认证为某个已知用户；返回结果中会包含 `authenticated`、`user.username`、`user.uid`、`user.groups` 与兼容的 `audiences` 等字段。

在 Vault 的 Kubernetes 认证方法里，Vault 自身不是 Kubernetes ServiceAccount Token 的最终权威；Vault 调用 TokenReview，由 Kubernetes API server 确认 token 是否仍然有效，再由 Vault 根据 role 中的 service account 名称、namespace、namespace selector、audience 与 token policy 配置决定是否签发 Vault token。

---

## 3. 一次登录的完整数据流

一次标准登录可以拆成五步：Pod 读取自己挂载的 ServiceAccount JWT；Pod 将 `role` 与 `jwt` 提交到 `auth/kubernetes/login`；Vault 使用配置好的 Kubernetes 连接信息调用 TokenReview；Kubernetes API server 返回该 JWT 对应的 ServiceAccount 身份；Vault 检查 role 约束并签发 Vault token。

![Kubernetes 认证流程手绘示意](/images/ch4-k8s/kubernetes-auth-tokenreview-flow.png)

该流程有一个容易被忽略的安全含义：Pod 的 ServiceAccount JWT 会通过网络交给 Vault；这里成立的前提是 Vault 不是普通应用，而是被纳入信任边界、专门负责身份验证与凭据签发的特殊安全组件。HashiCorp 文档把 Vault 视作可信计算基的一部分，因此 Pod 把 JWT 交给 Vault 是这套认证设计的一环；但普通 Kubernetes 应用不具备这种特殊地位，不应接收或转存其他 Pod 的 JWT，因为这等同于允许第三方代表该 Pod 调用 Kubernetes API。

![ServiceAccount JWT 共享边界提醒漫画](/images/ch4-k8s/serviceaccount-jwt-sharing-warning.png)

---

## 4. 启用与基础配置

Kubernetes 认证方法在使用前必须由运维或配置管理工具预先启用与配置；默认挂载路径是 `auth/kubernetes/`，启用命令是 `vault auth enable kubernetes`。

`auth/kubernetes/config` 通常需要让 Vault 知道 Kubernetes API server 的地址、用于校验 TLS 的 CA 证书，以及用于访问 TokenReview API 的 reviewer 凭据；不过 `token_reviewer_jwt` 并非总是显式必填，Vault 在 Kubernetes Pod 内运行时可以使用本地 ServiceAccount token，也可以在特定配置下使用客户端提交的 JWT 访问 TokenReview API。

如果 Vault 自己运行在 Kubernetes Pod 中，并且采用本地 ServiceAccount token 作为 reviewer JWT，那么 Vault 1.9.3 起会周期性重新读取本地 ServiceAccount token 文件，以适配短生命期 token；这种模式要求配置时省略 `token_reviewer_jwt` 与 `kubernetes_ca_cert`，只显式提供 `kubernetes_host`，Vault 会从默认挂载目录加载本地 token 与 CA 证书。

`disable_local_ca_jwt=true` 可以理解为告诉 Vault：“不要自动使用 Pod 里默认挂载的那份 ServiceAccount JWT 和 Kubernetes CA 证书。”启用这个开关后，如果你又没有通过 `kubernetes_ca_cert` 明确提供 Kubernetes API server 的 CA 证书，Vault 就只能改用操作系统自己的系统信任库来验证 Kubernetes API server 的 TLS 证书。这个选项通常用于一种更刻意的部署方式：管理员不希望 Vault 插件悄悄依赖 Pod 本地挂载的身份材料，而是希望把 reviewer JWT、CA 证书或系统信任来源都明确纳入配置管理。

这样做的主要收益是让信任来源可预期、可审计、可轮换：管理员可以清楚说明 Vault 用哪一个 reviewer JWT 调用 TokenReview、用哪一个 CA 证书或系统信任库校验 Kubernetes API server，而不是让插件根据运行环境中是否存在默认挂载文件自动决定。对于跨集群、受合规约束、由 GitOps 或配置管理系统统一下发的部署，这能减少环境差异带来的误判，也能避免 Pod 本地 token 的权限、轮换周期和使用边界变得不透明。

启用与配置的三种典型写法：

```bash
# A：Vault 运行在 Kubernetes Pod 内，使用本地 ServiceAccount token 作为 reviewer
vault auth enable kubernetes
vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"

# B：Vault 在集群外，显式提供 reviewer JWT 与 CA
vault write auth/kubernetes/config \
    kubernetes_host="https://kube-apiserver.example.com:6443" \
    kubernetes_ca_cert=@/etc/kubernetes/pki/ca.crt \
    token_reviewer_jwt="$(cat /root/vault-reviewer.jwt)" \
    disable_local_ca_jwt=true

# C：使用客户端提交的 JWT 去调 TokenReview（需各客户端 SA 拥有 system:auth-delegator）
vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    use_annotations_as_alias_metadata=false
```

为 Vault 本身或外部 reviewer ServiceAccount 授权 TokenReview：

```bash
kubectl create serviceaccount vault-auth -n vault
kubectl create clusterrolebinding vault-auth-delegator \
    --clusterrole=system:auth-delegator \
    --serviceaccount=vault:vault-auth
```

---

## 5. Role：把 Kubernetes 身份映射到 Vault policy

Kubernetes auth 的 role 是 Vault 侧的授权边界：登录请求先经 TokenReview 证明“这是谁”，再由 role 判断“这个 ServiceAccount 是否允许以这个 Vault role 登录，以及登录后获得哪些 Vault policy”。

role 的必填身份约束是 `bound_service_account_names`；生产配置通常还会显式写明 `bound_service_account_namespaces` 或 `bound_service_account_namespace_selector` 之一，并配置 `token_policies`（旧字段为 `policies`）与 `token_ttl` 等 token 参数。HashiCorp 文档示例把名为 `myapp`、位于 `default` namespace 的 ServiceAccount 绑定到一个 `demo` role，并给它 `default` policy 与 1 小时 TTL。

`bound_service_account_names` 是必填约束，表示哪些 ServiceAccount 名称可以登录该 role；值为 `*` 时允许任意名称，但仍应配合 namespace、audience 或 policy 边界使用，否则 role 的授权面会过大。

`bound_service_account_namespaces` 可以列出允许登录的 namespace，值为 `*` 时允许任意 namespace；`bound_service_account_namespace_selector` 可以使用 namespace label selector 选择允许登录的 namespace，并且当它与显式 namespace 列表同时配置时，两者之间是 OR 关系。

`audience` 用来校验 JWT 的 audience claim，即“这个 token 原本是发给哪个接收方使用的”；Kubernetes TokenReview 也支持 audience 字段，并要求 audience-aware 的认证器返回与 token 兼容的 audience，因此在 Vault role 中设置 audience 可以降低 token 被跨系统误用的范围。

一个完整的 role + policy 示例：

```bash
vault policy write myapp-read - <<'EOF'
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/myapp \
    bound_service_account_names=myapp \
    bound_service_account_namespaces=default \
    audience=vault \
    token_policies=myapp-read \
    token_ttl=1h \
    token_max_ttl=24h

vault read auth/kubernetes/role/myapp
```

---

## 6. Reviewer JWT 与 RBAC 权限

Vault 调用 TokenReview API 时必须持有一个能创建 TokenReview 的 Kubernetes 凭据；在启用 RBAC 的集群中，文档示例通过把某个 ServiceAccount 绑定到内置 `system:auth-delegator` ClusterRole 来授予这项权限。

Kubernetes API server 应启用 `--service-account-lookup`，该选项从 Kubernetes 1.7 起默认为 true；如果没有启用，已删除的 token 可能无法被正确撤销，从而仍能通过 Kubernetes auth 登录 Vault。

当 role 使用 namespace selector 时，Vault 必须能读取 Kubernetes namespace；当配置 `use_annotations_as_alias_metadata=true` 时，Vault 必须能读取 ServiceAccount，因为它需要从 ServiceAccount 注解中提取 alias metadata。

---

## 7. Kubernetes 1.21+：短生命期 token 与 issuer 变化

Kubernetes 1.21 起，`BoundServiceAccountTokenVolume` 特性默认启用；这改变了容器中默认挂载的 ServiceAccount JWT：它具有过期时间，并且绑定到 Pod 与 ServiceAccount 的生命周期，同时 JWT 的 `iss` claim 取决于集群自身配置。

Vault 1.9.0 起，新的 Kubernetes auth mount 默认 `disable_iss_validation=true`，并且 `issuer` 与 `disable_iss_validation` 字段已被标记为弃用；官方解释是 Kubernetes API 在 TokenReview 时已经执行 issuer 相关校验，Vault 侧重复校验会让同一套配置难以同时兼容 Kubernetes 1.20 与 1.21 的默认 token。

如果你确实启用了 Vault 侧 issuer 校验，Kubernetes 1.21+ 集群可能需要把 Vault 配置中的 `issuer` 设置为 kube-apiserver `--service-account-issuer` 的值；文档给出两种发现方式：解码一个 TokenRequest 返回的 JWT，或读取集群的 `/.well-known/openid-configuration`。

---

## 8. 四种短生命期 token 处理策略

Kubernetes 1.21 以后，Pod 默认拿到的 ServiceAccount token 更像一张“短期通行证”：它会过期，也会跟 Pod 或 ServiceAccount 的生命周期绑定。于是 Vault 在调用 TokenReview 时，需要先决定一件事：它用哪一张“通行证”去问 Kubernetes API server“这个 Pod token 现在还有效吗？”这里的 reviewer JWT，就可以先理解为 Vault 用来向 Kubernetes 发起这次询问的凭据。

围绕这个问题，官方文档给了四种常见选择：让 Vault 使用自己 Pod 里的本地 token；让客户端把自己的 JWT 交给 Vault，并由 Vault 用这枚 JWT 去做 TokenReview；继续使用一个手工准备的长期 reviewer token；或者不走 Kubernetes auth method，改用 JWT auth method 按 OIDC 的方式验证 Kubernetes token。

| 策略 | 所有 token 是否短生命期 | 是否可提前撤销 | 主要代价 |
| :--- | :--- | :--- | :--- |
| 使用 Vault 本地 ServiceAccount token 作为 reviewer JWT | 是 | 是 | Vault 需要运行在 Kubernetes 集群中，并要求 Vault 1.9.3+ 才能周期性重读本地 token |
| 使用客户端 JWT 作为 reviewer JWT | 是 | 是 | 每个允许登录 Vault 的客户端 ServiceAccount 都需要具备 `system:auth-delegator` 权限 |
| 继续使用长期 reviewer token | 否 | 是 | 保持旧流程，但不能获得短生命期 token 的安全收益 |
| 改用 JWT auth method | 是 | 否 | 不需要 reviewer JWT，但客户端 token 在 TTL 到期前不能被提前撤销 |

这张表不是在说哪一种永远最好，而是在提醒你先想清楚取舍：能不能接受长期凭据；删除 Pod 或 ServiceAccount 后，是否必须立刻禁止它继续登录 Vault；以及是否愿意为客户端 ServiceAccount 额外配置 RBAC 权限。

![短生命期 token 策略地图](/images/ch4-k8s/kubernetes-reviewer-token-strategies.png)

---

## 9. Identity alias：UID 默认更安全，名称映射更可控

Kubernetes auth role 的 `alias_name_source` 控制 Vault Identity alias 的生成方式；默认值是 `serviceaccount_uid`，官方将其描述为推荐且更安全的方式，因为 UID 是 Kubernetes 为对象生成的机器标识，同名 ServiceAccount 被删除后重建也会得到不同 UID。

`alias_name_source=serviceaccount_name` 会使用 ServiceAccount 的 namespace 与名称作为 alias name，例如 `vault/vault-auth`；官方仅建议在明确接受风险或能通过强控制缓解 ServiceAccount 创建、删除与访问风险时使用，因为同名对象重建可能影响 Vault 身份映射的语义。

---

## 10. 注解到 alias metadata：把 Kubernetes 标签信息带入 Vault policy

当 `use_annotations_as_alias_metadata=true` 时，Vault 会把客户端 token 对应 ServiceAccount 上以 `vault.hashicorp.com/alias-metadata-` 为前缀的注解写入 Vault alias metadata；注解键去掉前缀后的部分成为 metadata key，注解值成为 metadata value。

由于 Vault alias metadata 本身存在取值长度限制，官方要求这些注解值不超过 512 个字符；超过该限制会导致注解无法作为 alias metadata 使用。

这项能力常与 templated policy 配合使用：例如把 ServiceAccount 注解 `vault.hashicorp.com/alias-metadata-env: demo/app` 写入 alias metadata 后，可以在 Vault policy 中通过 `identity.entity.aliases.<mount accessor>.metadata.env` 渲染出该工作负载专属的 KV 路径。

官方同时指出，启用注解到 alias metadata 时 Vault 必须有权限读取 Kubernetes ServiceAccount；这是因为 Vault 需要在登录过程中查询 ServiceAccount 对象并读取其注解。

完整例子：ServiceAccount 注解 + role 启用注解映射 + templated policy：

```bash
# 1. 在 ServiceAccount 上打注解
kubectl annotate serviceaccount myapp -n default \
    vault.hashicorp.com/alias-metadata-env=demo \
    vault.hashicorp.com/alias-metadata-app=myapp

# 2. 允许 Vault 读取 SA 对象
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vault-sa-reader
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-sa-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vault-sa-reader
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: vault
EOF

# 3. role 开启注解 → alias metadata
vault write auth/kubernetes/role/myapp \
    bound_service_account_names=myapp \
    bound_service_account_namespaces=default \
    audience=vault \
    alias_name_source=serviceaccount_uid \
    use_annotations_as_alias_metadata=true \
    token_policies=myapp-templated \
    token_ttl=1h

# 4. 获取 mount accessor 并写 templated policy
ACCESSOR=$(vault auth list -format=json | jq -r '."kubernetes/".accessor')

vault policy write myapp-templated - <<EOF
path "secret/data/{{identity.entity.aliases.${ACCESSOR}.metadata.env}}/{{identity.entity.aliases.${ACCESSOR}.metadata.app}}/*" {
  capabilities = ["read"]
}
EOF
```

---

## 11. CLI 与 API 登录形式

CLI 层面，默认路径是 `/kubernetes`，可以直接写入登录端点：`vault write auth/kubernetes/login role=demo jwt=...`；如果认证方法挂载在其他路径，命令中的 `kubernetes` 需要替换为实际 mount path。

API 层面，默认端点是 `POST /v1/auth/kubernetes/login`，请求体包含 `role` 与 `jwt`；如果认证方法挂载在其他路径，API 路径中的 `kubernetes` 同样需要替换为实际 mount path；响应中的 Vault token 位于 `auth.client_token`，metadata 会包含 role、ServiceAccount 名称、namespace、secret name 与 UID 等信息。

官方 Go 示例使用 Vault API 客户端中的 Kubernetes auth helper 读取 ServiceAccount token 文件并登录 Vault；这反映了实际应用中的常见方式：应用从默认挂载路径或管理员指定路径读取本 Pod 的 token，然后把它交给 Vault。

在 Pod 内登录的最小脚本：

```bash
# Pod 默认挂载的 SA token
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# CLI
vault write auth/kubernetes/login role=myapp jwt="$JWT"

# HTTP API
curl -sS --request POST \
  --data "{\"role\":\"myapp\",\"jwt\":\"$JWT\"}" \
  "$VAULT_ADDR/v1/auth/kubernetes/login" | jq -r '.auth.client_token'

# 一步到位：导入 token 并读取 secret
export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
    role=myapp jwt="$JWT")
vault kv get secret/myapp/config
```

需要明确 audience/TTL 时使用 projected token：

```yaml
volumes:
  - name: vault-token
    projected:
      sources:
        - serviceAccountToken:
            path: vault-token
            audience: vault
            expirationSeconds: 600
volumeMounts:
  - name: vault-token
    mountPath: /var/run/secrets/vault
    readOnly: true
```

---

## 12. 生产使用时的边界条件

Kubernetes auth 方法专门围绕 Kubernetes TokenReview API 设计；同一枚 Kubernetes ServiceAccount Token 也可以通过 Vault JWT auth method 作为 OIDC token 验证，但 JWT auth 的重要差异是客户端 token 在 TTL 到期前不能被提前撤销，因此官方建议在采用该方案时保持 TTL 较短。

长期 ServiceAccount token 仍可通过手工创建 `kubernetes.io/service-account-token` Secret 得到，并可继续作为 `token_reviewer_jwt` 使用；但 HashiCorp 文档明确说明这种做法只是维持旧工作流，并不能获得短生命期 token 的安全姿态收益。

Kubernetes 官方文档也不推荐把长期 bearer token 作为外部应用的默认认证方式，因为一旦泄露便可被滥用；更推荐 TokenRequest 这类短生命期 token，或采用受良好保护的证书、私钥、认证 webhook 等替代方式。

---

## 13. 本章实验设计

Killercoda Creator 文档提供 `kubernetes-kubeadm-1node` 后端环境，它包含一个 kubeadm 单节点集群，control plane 的 taint 已移除，可以直接调度工作负载；本章实验选择这个环境，以便在真实 Kubernetes API server 上运行 TokenReview，而不是用静态字符串模拟登录。

Killercoda 场景使用 `index.json` 描述标题、intro、steps、finish、backend 与界面布局；本章实验沿用项目既有格式，把环境准备放在 intro 的 background/foreground 脚本里，把学习流程拆成四个 step。

实验会依次完成：启用 `auth/kubernetes` 并配置 reviewer JWT；创建 `myapp` ServiceAccount 并完成一次真实登录；验证 ServiceAccount 名称、namespace selector 与 audience 约束；最后启用 annotation alias metadata 与 templated policy，让 Kubernetes 注解参与 Vault policy 渲染。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-k8s" title="实验：Kubernetes 认证完整动手——TokenReview、ServiceAccount 约束、audience 与模板化策略" />

---

## 参考文档

- [Kubernetes Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes Auth API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [Kubernetes Service Accounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
- [Kubernetes TokenReview API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/)
- [Killercoda Creator Documentation](https://killercoda.com/creators)
