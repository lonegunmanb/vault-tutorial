---
order: 311
title: 3.11 Kubernetes 机密引擎：让 Vault 为 K8s 集群签发动态 ServiceAccount Token
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.11 Kubernetes 机密引擎：让 Vault 为 K8s 集群签发动态 ServiceAccount Token

> **核心结论**：Kubernetes 机密引擎（`kubernetes/`）让 Vault 主动调用目标集群的
> **TokenRequest API**（Kubernetes v1.22 起稳定），按需为某个 ServiceAccount 签出短生命期的 SA Token。
> 它与 [Kubernetes 认证方法](/) （让 Pod 登录 Vault，未来 7.X 章）是**完全相反的方向**。
> 引擎围绕一个 `manager SA` 建立信任，并通过三种 Role 模式覆盖从最保守到最灵活的全部场景：
> `service_account_name`（借用现有 SA）、
> `kubernetes_role_name`（动态绑定到现有 Role）、
> `generated_role_rules`（连 Role 都现场生成）。
> 三种模式的关键差异体现在 **Vault 会创建哪些 K8s 对象**，以及 **Lease 到期时清理什么**。

参考：
- [Kubernetes Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/kubernetes)
- [Kubernetes Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/kubernetes)
- 同模型对照：[3.3 AWS 引擎](/ch3-aws)、[3.10 LDAP 引擎](/ch3-ldap)
- TODO: 反向参考：未来 4.X Kubernetes 认证方法

![k8s-secrets-engine-story](/images/ch3-k8s/k8s-secrets-engine-story.png)


---

## 1. 必先澄清的"Vault × K8s"三件套

很多人开始接触时会混淆三个完全不同的功能：

| 组件 | 方向 | 发起者 | 目标 | 凭据流向 |
| --- | --- | --- | --- | --- |
| **Kubernetes 认证方法** (`auth/kubernetes`) | ⬆️ 入站 | Pod（在 K8s 集群内） | Vault | Pod SA JWT → Vault → 颁发 Vault Token |
| **Kubernetes 机密引擎** (`secret/kubernetes`，本章主角） | ⬇️ 出站 | Vault | K8s API | Vault 持 manager SA → 颁发新的 SA Token |
| **Vault Secrets Operator / Agent Injector** | 🔄 同步/注入 | K8s 控制器 / Pod 内 Vault Agent | Vault 与 K8s 工作负载 | Vault → K8s Secret（VSO）或 Pod 内文件（Agent Injector） |

**典型场景**：

- "**Pod 怎么读 Vault 里的密码？**" → 用 K8s **认证方法** + VSO/Sidecar
- "**Vault 怎么代我去操作目标 K8s 集群？**" → 用本章的 K8s **机密引擎**

> **顺带一提**：官方文档明确**不推荐**用本引擎签出来的 K8s SA token 反过来去走 Vault 的 Kubernetes 认证方法——这会在 Vault 里生成大量难以管理的独立身份。

---

## 2. 工作原理：manager SA + TokenRequest API

### 2.1 Manager SA

Vault 在目标 K8s 集群里需要一个能代表 Vault 调用 K8s API 的 ServiceAccount。
如果 Vault 通过官方 Helm chart 跑在同一个集群内，这通常就是 Vault Server Pod 自己的 ServiceAccount，默认名称随 Helm release 而定（常见为 `vault`，也可通过 `server.serviceAccount.name` 改名）。
如果 Vault 跑在集群外，也可以单独创建一个管理用 ServiceAccount；本章实验把这个角色称为 `vault-manager`。

按三种模式拆解，manager SA 大致需要：

| 模式 | 必需的 K8s 权限（在 manager SA 上） |
| --- | --- |
| A. `service_account_name` | `serviceaccounts/token: [create]` |
| B. `kubernetes_role_name` | A 全部 + `serviceaccounts: [create,update,delete]` + `rolebindings`/`clusterrolebindings: [create,update,delete]`；若绑定自己并不具备全部权限的 Role/ClusterRole，还需要相应的 `bind` 权限 |
| C. `generated_role_rules` | B 全部 + `roles`/`clusterroles: [create,update,delete]`；若生成自己并不具备全部权限的 Role/ClusterRole，还需要相应的 `escalate` 权限 |

这里的权限行是按实际创建对象拆出来的理解版；落地时还要根据是否使用 `ClusterRole` / `ClusterRoleBinding`、是否使用 namespace label selector，以及集群自身 RBAC 策略调整。

> **`bind` 和 `escalate` 是关键**：K8s 的"反权限提升"机制要求——你不能用自己没有的权限去创建一个 Role。
> 所以当 Vault 要绑定或生成超出 manager SA 自身权限集合的 RBAC 规则时，必须显式持有对应的 `bind` / `escalate` 权限。

### 2.2 一次申领的内部流程

![k8s-credential-flow](/images/ch3-k8s/k8s-credential-flow.png)

---

## 3. 启用与配置

```bash
# 1) 启用引擎
vault secrets enable kubernetes

# 2) 写入配置（Vault 在集群外，需手工提供 host / CA / token）
vault write kubernetes/config \
  kubernetes_host="https://192.168.1.100:6443" \
  kubernetes_ca_cert=@/path/to/ca.crt \
  service_account_jwt=@/path/to/manager-token.txt
```

> **如果 Vault Pod 跑在同一个集群里**：直接执行空配置写入即可，
>
> ```bash
> vault write -f kubernetes/config
> ```
>
> Vault 会自动读 `/var/run/secrets/kubernetes.io/serviceaccount/{ca.crt,token}` 与 `KUBERNETES_SERVICE_*` 环境变量。

> **K8s 1.24+ 取消了自动 SA Secret**：本实验在 background.sh 中显式创建了一个
> `kubernetes.io/service-account-token` 类型的 Secret 来生成 manager 的长期 token。
> 这种方式只适合实验或确实需要长期 token 的场景；生产环境应优先考虑短期 token 或让 Vault 直接使用 Pod 内挂载的本地 ServiceAccount token。

---

## 4. 三种 Role 模式深度对照

| 维度 | A. `service_account_name` | B. `kubernetes_role_name` | C. `generated_role_rules` |
| --- | --- | --- | --- |
| **目标 SA** | 借用已有 SA | 现场创建临时 SA | 现场创建临时 SA |
| **绑定的 Role** | 已有 RoleBinding/ClusterRoleBinding（不动） | 现场建 RoleBinding/ClusterRoleBinding，引用**已有** Role/ClusterRole | 现场建 RoleBinding/ClusterRoleBinding，引用**现场建的** Role/ClusterRole |
| **Vault 创建的对象** | （仅 token） | SA + RoleBinding/ClusterRoleBinding | SA + RoleBinding/ClusterRoleBinding + Role/ClusterRole |
| **Lease 到期清理** | （token 自然过期） | 删 SA + RoleBinding/ClusterRoleBinding；Role/ClusterRole 留 | 删 SA + RoleBinding/ClusterRoleBinding + Role/ClusterRole |
| **manager SA 权限** | 仅 `serviceaccounts/token:create` | + `serviceaccounts` 与 `rolebindings`/`clusterrolebindings` 的创建/更新/删除权限；必要时还要 `bind` | + `roles`/`clusterroles` 的创建/更新/删除权限；必要时还要 `bind` / `escalate` |
| **审计区分度（经验判断）** | 弱（多次申领同一 SA） | 强（每次新 SA） | 强（每次新 SA + Role） |
| **典型适用场景（经验判断）** | 已有 SA，按需短期化它的 token | 权限固定但每次想要"新身份" | 权限本身要动态生成（多租户） |

### 4.1 模式 A：`service_account_name`

```bash
vault write kubernetes/roles/mode-a \
  allowed_kubernetes_namespaces="default" \
  service_account_name="viewer-sa" \
  token_default_ttl="10m"
```

申领出来的 token 就是 `viewer-sa` 的 token，权限完全跟随它现有的 RoleBinding。
Lease 到期不会清理任何 K8s 对象（token 自然过期足以）。

### 4.2 模式 B：`kubernetes_role_name`

```bash
vault write kubernetes/roles/mode-b \
  allowed_kubernetes_namespaces="default" \
  kubernetes_role_name="pod-reader" \
  token_default_ttl="10m"
```

每次申领时 Vault 现场建一个临时 SA，并用同名的临时 RoleBinding 绑到现有的 `pod-reader`。
Lease 到期时这两个临时对象自动删除，`pod-reader` Role 本身不动（可被其它 binding 复用）。

### 4.3 模式 C：`generated_role_rules`

```bash
vault write kubernetes/roles/mode-c \
  allowed_kubernetes_namespaces="default" \
  generated_role_rules='rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","list"]' \
  token_default_ttl="10m"
```

每次申领时 Vault 用 YAML 规则现场建一个 Role + 一个 SA + 一个 RoleBinding，**三件套**。
Lease 到期全部消失。若生成的规则包含 manager SA 自己并不具备的权限，本模式就需要 manager SA 持有相应的 `bind` + `escalate`。

---

## 5. 申领与生命周期

```bash
vault write kubernetes/creds/mode-b \
  kubernetes_namespace=default \
  ttl=5m
```

返回示例：

```
Key                          Value
---                          -----
lease_id                     kubernetes/creds/mode-b/abc...
lease_duration               5m
lease_renewable              false
service_account_name         v-root-mode-b-1714125...
service_account_namespace    default
service_account_token        eyJhbGciOiJSUzI1NiIs...
```

可选参数：

| 参数 | 含义 |
| --- | --- |
| `kubernetes_namespace` | 若 Vault role 只允许一个具体命名空间（且不是 `*`），可省略；否则必填 |
| `ttl` | 覆盖 role 默认 TTL；实际返回值可能被 K8s、Vault 系统 TTL 或 role 的 `token_max_ttl` 截断 |
| `cluster_role_binding=true` | 在 B/C 且 Vault role 的 `kubernetes_role_type=ClusterRole` 时，生成 ClusterRoleBinding 而非 RoleBinding |
| `audiences="..."` | 给 TokenRequest 指定非默认受众 |

**Token 是标准的 K8s SA JWT**，可直接：

```bash
kubectl --token="$TOKEN" -n default auth can-i list pods
```

---

## 6. 与其它章节的关系

```
[2.3 Lease]                ← 全部 Token 生命周期由 Lease 驱动
[3.1 Secrets Engines]      ← 引擎通用框架
[3.3 AWS]                  ← 同模型：Vault → 外部系统签发短期凭据
[3.10 LDAP]                ← 同模型：清理对象不同（LDAP entry / K8s 对象）
[3.11 Kubernetes 引擎] ◄── 你在这儿
[未来 7.X K8s Auth]        ← 反向：Pod → Vault
[未来 8.X VSO / Injector]  ← 把"动态 K8s 凭据"投递到业务 Pod
```

---

## 7. 三个最容易踩的坑

1. **不要把 TokenRequest 和旧式 SA Secret 混为一谈** —— 本引擎通过 TokenRequest 子资源签发短期 token；Kubernetes 文档将 TokenRequest API 标注为 v1.22 起 stable。不要指望它自动降级为旧式 Secret token；如果目标集群不支持该子资源，申领会失败。本实验使用 Killercoda 预置的 kubeadm 单节点 Kubernetes 环境。

2. **模式 C 报 `forbidden: attempting to grant RBAC permissions not currently held` 一类错误** ——
   这是 K8s 反权限提升保护：manager SA 必须显式持 `roles/clusterroles: [bind,escalate]`，否则不能创建包含它"自己没有"权限的 Role。

3. **`vault read kubernetes/config` 看不到 token 是正常的** —— `service_account_jwt` 是机密字段，
  写入后**永远不会回显**。如果想检验配置，直接 `vault write kubernetes/creds/<role> kubernetes_namespace=<ns>` 试一次申领。

---

## 参考文献

- [Kubernetes Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/kubernetes)
- [Kubernetes Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/kubernetes)
- [Kubernetes RBAC — `bind` and `escalate` verbs](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping)
- [TokenRequest API (KEP-1205)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/1205-bound-service-account-tokens)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-k8s"/>
