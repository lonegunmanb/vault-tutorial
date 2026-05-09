---
order: 76
title: 7.6 Kubernetes 集成模式之三：Vault Secrets Operator (VSO) 控制器与 CRD 模型
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.6 Kubernetes 集成模式之三：Vault Secrets Operator (VSO) 控制器与 CRD 模型

> **核心结论**：Vault Secrets Operator (VSO) 是 HashiCorp 官方维护的 Kubernetes Operator，它在集群中常驻一组控制器进程，监听以 `secrets.hashicorp.com/v1beta1` 为 API group 的自定义资源（CRD），把 Vault 中的「源」机密物化为同命名空间内原生 Kubernetes Secret 的「目的端」。Pod 像消费普通 K8s Secret 一样消费这些数据；机密在 Vault 侧的变更由控制器调谐器（reconciler）持续追平，并可触发关联工作负载的 rollout-restart。

参考：

- [Vault Secrets Operator — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
- [Install and upgrade the Vault Secrets Operator — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [Vault Secrets Operator — Vault source — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault)
- [Vault authentication in detail — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault/auth)
- [Vault Secrets Operator API Reference — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [Persist and encrypt the Vault client cache — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault/client-cache)
- [Instant updates for a VaultStaticSecret — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault/instant-updates)
- [Vault Secrets Operator examples — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/examples)
- [Run the Vault Secrets Operator on OpenShift — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/openshift)

---

## 1. VSO 在 Kubernetes 接入链路中的位置

VSO 与第 7.4 节的 Vault Agent Sidecar Injector、第 7.5 节的 Secrets Store CSI Provider 并列，是官方推荐的第三种 Kubernetes 接入形态。它的特征是：常驻一组控制器进程（`controller-manager`），监听集群内多种自定义资源定义（CRD），并把「来源」机密直接写入「目的端」的原生 Kubernetes Secret 对象，应用容器只需以标准方式（`secretKeyRef`、`envFrom`、Volume 挂载）消费这个 Secret 即可。

与 Sidecar Injector 不同，VSO 不会向应用 Pod 中注入额外容器；与 CSI Provider 不同，VSO 的产物不是按 Pod 生命周期挂载的临时 volume，而是集群中一份持久存在的 Kubernetes Secret 对象。控制器周期性地比对源数据与目的端数据的差异并执行同步，因此 Vault 侧的更新可以在不重启应用 Pod 的前提下自动反映到 Kubernetes Secret 中。

VSO 同时支持以 Vault Community/Enterprise（1.11+）以及 HCP Vault Dedicated（1.11+）作为来源。本课程聚焦于开源 Vault 1.17+ 与 VSO 0.10.0 的组合；涉及 Vault Enterprise 才能启用的能力（如基于事件订阅的 instant updates）会在文中明确标注。

![Vault Secrets Operator 在集群内常驻控制器进程，监听 VaultConnection / VaultAuth / VaultStaticSecret 等 CRD，把 Vault 源机密物化为应用命名空间下的原生 Kubernetes Secret，再由 Pod 通过 secretKeyRef 或 envFrom 消费](/images/ch7-vso/vso-controller-flow.png)

---

## 2. 控制器协调模型：source → destination 的持续同步

VSO 的运行模型是经典的 Kubernetes Operator 控制器模式：控制器观察其支持的一组 CRD，每个 CRD 描述「从某种 source 同步到一个 Kubernetes Secret」的规约。控制器把 source 的机密数据直接写入 destination Kubernetes Secret，并在生命周期内持续把 source 的变化同步到 destination。应用只需要拥有读取 destination Secret 的权限即可使用其中的数据。

控制器除了周期性同步以外，还会执行**漂移检测与修复（drift detection and remediation）**：当 destination Kubernetes Secret 在控制器之外被修改（例如有人手动 `kubectl edit secret`），下一轮调谐会以 source 数据为准重新写回。VSO 的 `VaultStaticSecret` 默认开启 `hmacSecretData=true`，让控制器在 status 中记录数据的 HMAC 值用作比对依据。

VSO 同时支持的 source 不止 Vault 一种，包括 HCP Vault Secrets（`HCPVaultSecretsApp`）等。它们与 Vault 来源共用同一套 destination 与 transformation 模型。本节后续讨论聚焦于 Vault source。

---

## 3. 基础 CRD：`VaultConnection` 与 `VaultAuth`

VSO 通过两个基础 CRD 描述「连接到哪个 Vault」和「以什么身份连接」。`VaultConnection` 提供 Vault 服务器地址、可选 HTTP headers、TLS server name、CA 证书引用、`skipTLSVerify` 与请求超时等连接参数。

`VaultAuth` 描述如何登录该 Vault 实例。其 `vaultConnectionRef` 字段引用上面的 `VaultConnection`；如果留空，控制器会回退到 operator 自身命名空间下名为 `default` 的 `VaultConnection`。`spec.method` 是认证方法名（取值范围：`kubernetes`、`jwt`、`appRole`、`aws`、`gcp`），`spec.mount` 指定该方法在 Vault 中挂载的路径，对应字段还包括 `kubernetes`、`jwt`、`appRole`、`aws`、`gcp` 等方法专属配置块。

`VaultAuth` 中的 `kubernetes` 块包含 `role`、`serviceAccount`、`audiences` 与 `tokenExpirationSeconds` 等字段。其中 `serviceAccount` 必须位于「消费者机密 CR」（即 `VaultStaticSecret` 等 CR）所在的 Kubernetes 命名空间内；这是 VSO 跨命名空间访问的硬约束，目的是防止 A 命名空间利用 B 命名空间的 ServiceAccount 间接访问 B 命名空间能访问的 Vault 数据。

`VaultAuth` 还提供 `allowedNamespaces` 字段，用于控制哪些 Kubernetes 命名空间内的机密 CR 可以引用该 `VaultAuth`：未设置时，只允许 operator 自身命名空间和 `VaultAuth` 自身命名空间使用；设为 `["*"]` 时放开为全部命名空间；也可以列出具体命名空间名。

VSO 0.8.0+ 还提供可选的 `VaultAuthGlobal` CRD，用于把多份 `VaultAuth` 共享的认证配置（如同一种 method、mount、audiences 等）抽到全局对象中，由 `VaultAuth` 通过 `vaultAuthGlobalRef` 引用并选择性覆写。本课程为聚焦核心模型，主要使用直接配置的 `VaultAuth`，不强制使用 `VaultAuthGlobal`。

![三层 CRD 关系：VaultConnection 承载“连到哪个 Vault”，VaultAuth 承载“以什么身份和角色登录”，VaultStaticSecret/VaultDynamicSecret/VaultPKISecret 通过 vaultAuthRef 引用 VaultAuth 并声明同步到哪个 K8s Secret](/images/ch7-vso/vso-crd-layers.png)

---

## 4. 同步静态机密：`VaultStaticSecret`

`VaultStaticSecret` 把 Vault KV v1 或 KV v2 的一条记录同步到一个 Kubernetes Secret。其关键字段包括：`vaultAuthRef`（引用上一节的 `VaultAuth`，未设置则回退 operator 命名空间下名为 `default` 的 `VaultAuth`）、`mount`（KV 引擎在 Vault 中的挂载路径）、`type`（取值 `kv-v1` 或 `kv-v2`）、`path`（KV 路径）、`version`（仅 kv-v2 有效，对应版本查询参数）、`refreshAfter`（控制器刷新源数据的周期，取值如 `30s`、`1m`、`24h`）以及 `destination`（描述目的端 Kubernetes Secret 的 `name`、`create`、`overwrite`、`type`、`labels`、`annotations` 等）。

KV v2 的最小示例如下，请求路径 `kvv2/eng/apikey/google` 对应 Vault 的 `http://127.0.0.1:8200/v1/kvv2/eng/apikey/google`：

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  namespace: vso-example
  name: vault-static-secret-v2
spec:
  vaultAuthRef: vault-auth
  mount: kvv2
  type: kv-v2
  path: eng/apikey/google
  version: 2
  refreshAfter: 60s
  destination:
    create: true
    name: static-secret2
```



需要明确：`refreshAfter` 是控制器主动拉取并比对源数据的最小间隔。对于 KV 这类没有 lease TTL 的引擎，源数据是否变化由控制器在每个 `refreshAfter` 周期到来时通过比对 HMAC 判定；只要源数据未变，destination Kubernetes Secret 不会被无意义地覆写。

`destination` 中的 `type` 字段直接对应 Kubernetes Secret 的类型。VSO 会根据该类型对源数据做相应的格式化：例如把 `Destination.Type` 设置为 `kubernetes.io/dockerconfigjson`，可以让 VSO 直接产出可作为 `imagePullSecrets` 使用的拉取镜像凭据 Secret。

---

## 5. 触发应用滚动：`rolloutRestartTargets`

许多应用并不会在文件或环境变量变化时自动热加载。`VaultStaticSecret`、`VaultDynamicSecret`、`VaultPKISecret` 与 `HCPVaultSecretsApp` 都支持在 `spec.rolloutRestartTargets` 中声明一组目标工作负载（取值范围：`Deployment`、`DaemonSet`、`StatefulSet`、`argo.Rollout`）。当源机密在两次 reconcile 之间发生变化时，VSO 会通过给目标资源的 `spec.template.metadata.annotations` 打上形如 `vso.secrets.hashicorp.com/restartedAt: "2023-03-23T13:39:31Z"` 的时间戳，触发标准的 Kubernetes rollout-restart。

`rolloutRestartTargets` 与 `hmacSecretData` 之间存在一个重要约束：当 `VaultStaticSecret` 把 `hmacSecretData` 显式设为 `false` 时，所有配置的 `rolloutRestartTargets` 都会被忽略——因为没有 HMAC，控制器无法可靠地判定 Secret 是否真正发生了变化。本课程示例保留默认 `hmacSecretData=true`。

![rolloutRestartTargets 触发模型：reconcile loop 检测到源机密变化后，VSO 给目标 Deployment 的 pod template metadata.annotations 注入 vso.secrets.hashicorp.com/restartedAt 时间戳，由 Kubernetes 标准滚动机制重启 Pod](/images/ch7-vso/vso-rollout-trigger.png)

---

## 6. 动态机密与证书：`VaultDynamicSecret` 与 `VaultPKISecret`

`VaultDynamicSecret` 把 Vault 的动态机密引擎（如 `databases`、`aws`、`azure`、`gcp` 等）的一次响应同步为一个 Kubernetes Secret。其 `mount`、`path` 字段指向具体引擎与角色路径，例如 `mount: db` + `path: creds/my-postgresql-role` 对应 `http://127.0.0.1:8200/v1/db/creds/my-postgresql-role`。其它关键字段包括：`renewalPercent`（lease 进入续期的百分比阈值，默认 67，最大 90）、`revoke`（资源被删除时是否同时撤销 lease）、`allowStaticCreds`（用于 Database 引擎的 static-roles 等场景）。

`VaultDynamicSecret` 的刷新时机有两类来源：当 Vault 响应中带 lease duration 时，控制器以 lease 为准在 `renewalPercent` 时点续期/重新生成；当响应不携带 lease（例如某些非租约式引擎）时，需要通过 `refreshAfter` 显式指定一个时间间隔，且该值应落在源引擎配置的 `ttl`/`max_ttl` 范围内。

`VaultPKISecret` 用于把 Vault PKI 引擎签发的一张证书同步为 Kubernetes Secret，常见用法是配合 `destination.type: kubernetes.io/tls` 直接得到 `tls.crt` / `tls.key` 字段。关键字段包括：`mount`（PKI 引擎挂载点）、`role`（PKI role 名）、`commonName`、`altNames`、`ipSans`、`uriSans`、`ttl`、`format`、`expiryOffset`（在到期前多久触发续签的偏移），以及 `revoke`（资源被删除时是否撤销证书）。

`VaultPKISecret` 的 `destination.type` 与文本格式之间有约定：当类型是 `kubernetes.io/tls` 时，VSO 把 Vault 响应中的 `private_key` 写入 `tls.key`；把 `certificate` 与 `ca_chain` 拼接后写入 `tls.crt`（若 `ca_chain` 为空则使用 `issuing_ca`），并启用 `remove_roots_from_chain=true` 把根 CA 排除出链。

---

## 7. 客户端缓存与即时更新的能力边界

VSO 内部维护一份「Vault client cache」，用于缓存 Vault token 与动态机密 lease，使控制器在 leader 切换、滚动升级等场景下仍能延续既有 token/lease 的跟踪与续期。该缓存默认**不**持久化，也**不**默认开启加密；要把缓存持久化并加密存储到 Kubernetes Secret 中，需要在 Vault 侧启用 `transit` 机密引擎并准备加密密钥，再在 VSO Helm values 中把 `controller.manager.clientCache.persistenceModel` 设为 `direct-encrypted` 并配置 `storageEncryption` 块。

官方对动态机密场景给出强烈建议：如果使用 `VaultDynamicSecret`，应启用并加密 client cache，以便在 VSO 重启或升级后仍能维护既有 lease 而不是触发大量重新签发。本课程实验环境使用单节点 Killercoda Kubernetes，仅演示静态 KV 同步与 rolloutRestartTargets，不强制开启加密缓存；当读者把 VSO 投入生产时，应把这一项作为 Day-2 必做项。

`VaultStaticSecret` 还有一个名为「instant updates」的事件驱动更新通道：当 Vault 发生 KV 变更时，VSO 通过 Vault 的事件订阅 WebSocket 立刻收到通知并触发同步，不必等 `refreshAfter` 周期到来。该能力**仅适用于 Vault Enterprise 1.16.3+**，启用方式是在 `VaultStaticSecret.spec.syncConfig.instantUpdates` 中设为 `true`，并给绑定的 Vault 角色 policy 增加 `subscribe` capability 与 `sys/events/subscribe/kv*` 的读取权限。开源版 Vault 不支持这一通道，本课程仅简要提及。

---

## 8. 安装：Helm 路径与版本要求

VSO 的官方安装前置要求是 Kubernetes 1.23+ 与 Helm 3.7+；推荐通过 HashiCorp Helm 仓库的 `vault-secrets-operator` chart 安装。chart 0.10.0 对应 VSO 应用版本 0.10.0。

最小化安装命令如下：

```shell-session
$ helm repo add hashicorp https://helm.releases.hashicorp.com
$ helm install --version 0.10.0 \
    --create-namespace \
    --namespace vault-secrets-operator \
    vault-secrets-operator hashicorp/vault-secrets-operator
```



升级时使用 `helm upgrade`，并在执行前通过 `--dry-run` 预演变更。从 VSO 0.8.0 起，Helm chart 会在升级时自动更新 CRD，不再需要手动 `helm show crds | kubectl apply`；这是与 0.7.x 及更早版本相比的一项重要变化。

VSO 同时支持以 Kustomize 安装，但 Kustomize 安装路径不会部署默认的 `VaultAuthMethod`、`VaultConnection` 与 Transit 相关样例资源，也不支持 Helm 用于卸载时清理 finalizer 的 pre-delete hook。如非有特别需要，本课程一律使用 Helm 路径。

OpenShift 用户可通过内置 OperatorHub 安装，要求集群版本不低于 4.12；也可以使用 Helm chart，但通常需要把 `controller.manager.resources` 的 `memory` 请求/限制相对默认值上调，以避免 OOM 重启。

---

## 9. 选型小结：何时选择 VSO

如果团队希望应用以**完全声明式**方式消费 Vault 机密，并希望以**原生 Kubernetes Secret** 作为统一的二级缓存（即使 Vault 短时不可达，新建或扩容的 Pod 仍可从已同步的 Kubernetes Secret 启动），那么 VSO 是首选。VSO 把跨 Vault/K8s 的同步逻辑收敛在控制器中，应用工作负载本身保持纯粹的 Kubernetes 原生模型。

如果团队的首选是「机密只在 Pod 生命周期内以 volume 形式存在、不进入 K8s Secret 对象」，那么应使用第 7.5 节的 Secrets Store CSI Provider；如果团队仍以 Pod annotation 驱动机密注入并希望机密以共享内存文件形式呈现，则使用第 7.4 节的 Vault Agent Sidecar Injector。

VSO 与 CSI、Sidecar 这三种模式并不互斥，可以根据不同业务的合规与运维偏好在同一集群中共存。本章第 7.8 节会给出统一选型矩阵；本节读完后建议读者先以 VSO 完成最常见的 KV → K8s Secret 场景作为基线。

---

## 10. 互动实验

本节配套实验在 Killercoda 提供的 Kubernetes 单节点环境中完成。实验会用 Helm 安装 Vault dev server 与 VSO，启用 Kubernetes auth method，写入一条 KV v2 机密，再通过 `VaultConnection` + `VaultAuth` + `VaultStaticSecret` 三件套把该机密物化为应用命名空间下的原生 Kubernetes Secret，最后给 `VaultStaticSecret` 配置 `rolloutRestartTargets`，亲手验证 Vault 侧的更新如何触发 Deployment 滚动。

实验分为四步：第一步检查 VSO 控制器与 CRD；第二步创建 `VaultConnection` 与 `VaultAuth`，让 operator 能以 ServiceAccount 身份登录 Vault；第三步创建 `VaultStaticSecret` 把 Vault 的 `secret/vso/app` 同步为应用命名空间下的 `vso-app-secret`；第四步给 `VaultStaticSecret` 增加 `rolloutRestartTargets`，更新 Vault 中的密码，观察消费 Pod 是否被自动滚动重启。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-vso" title="实验：用 Vault Secrets Operator 把 Vault 机密同步为 K8s Secret 并触发滚动" />
