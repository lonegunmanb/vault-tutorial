---
order: 75
title: 7.5 Kubernetes 集成模式之二：Secrets Store CSI Driver + Vault Provider
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.5 Kubernetes 集成模式之二：Secrets Store CSI Driver + Vault Provider

> **核心结论**：Vault Secrets Store CSI provider 让 Pod 通过 Kubernetes 的 Secrets Store CSI volume 消费 Vault 机密。它的中心对象是 `SecretProviderClass`：该对象声明使用 `vault` provider、以哪个 Vault role 登录、以及从 Vault 读取哪些对象；当 Pod 创建并请求 CSI volume 时，Secrets Store CSI driver 会把请求交给 Vault provider，Vault provider 再以该 Pod 的 ServiceAccount 身份向 Vault 认证并把结果挂载进 Pod。

参考：

- [Vault Secrets Store CSI provider — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi)
- [Install the Vault Secrets Store CSI provider — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi/installation)
- [Vault Secrets Store CSI provider configurations — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi/configurations)
- [Vault Secrets Store CSI provider examples — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi/examples)

---

## 1. CSI provider 在 Kubernetes 接入链路中的位置

Vault Secrets Store CSI provider 并不是一个新的 Vault 机密引擎。官方将它描述为 Secrets Store CSI driver 的 Vault 专用 provider，让 Pod 通过 CSI volume 把 Vault 响应呈现为容器文件系统中的文件。使用它之前，集群里必须已经安装 Secrets Store CSI driver。

这条链路的声明入口是 `SecretProviderClass`。在该对象中，`spec.provider` 被设置为 `vault`，`spec.parameters.roleName` 声明登录 Vault 时使用的 role，`objects` 数组声明要读取的 Vault 路径、要抽取的字段以及最终文件名。官方示例把 `objectName` 解释为对象别名，同时也是写入容器中的文件名；`secretPath` 是 Vault 中的读取路径；`secretKey` 是从 Vault 响应中抽取具体值的字段名。

当带有 CSI volume 的 Pod 被创建时，Secrets Store CSI driver 会检查该 volume 引用的 `SecretProviderClass`。如果 provider 是 `vault`，请求会被转交给 Vault Secrets Store CSI provider；provider 使用这个 `SecretProviderClass` 与发起挂载的 Pod 的 ServiceAccount 去 Vault 获取机密，然后把结果写入该 Pod 的 CSI volume。

机密读取发生在 Pod 的 `ContainerCreation` 阶段。也就是说，容器真正启动之前，Secrets Store CSI driver 与 Vault provider 必须先从 Vault 读取机密并把数据写入 volume；如果这一步失败，Pod 会阻塞在创建阶段，而不是先启动应用再异步补齐文件。

![Secrets Store CSI driver 根据 Pod 的 CSI volume 请求找到 SecretProviderClass，再把 provider=vault 的请求交给 Vault Secrets Store CSI provider，由后者使用 Pod ServiceAccount 向 Vault 取回机密并写入挂载卷](/images/ch7-csi/csi-request-flow.png)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；画一个 Kubernetes 仓库码头。左侧是贴着“Pod”的小货车，车厢里有“CSI volume”空箱；中间是写着“Secrets Store CSI driver”的调度台，调度员查看“SecretProviderClass”清单；右侧是贴着“Vault Secrets Store CSI provider”的专用搬运员，拿着“ServiceAccount token”通行证去“Vault Server”保险库取出“secret file”包裹，再放回 Pod 的箱子里。专业词汇保持 English，其他标注使用中文。

---

## 2. 能力边界：文件、同步 Secret 与 Vault Agent 缓存

官方功能列表把 CSI provider 的能力归纳为七项：支持所有 Vault secret engines；使用请求挂载的 Pod 的 ServiceAccount 完成认证；支持与 Vault 的 TLS 和 mTLS 通信；把 Vault 机密渲染为文件；由 Agent 执行动态 lease 缓存与续期；可把机密同步为 Kubernetes Secret 以供环境变量使用；可通过 Vault Helm 安装。

其中“文件挂载”是最直接的消费方式。Pod 在 `volumeMounts` 中把 CSI volume 挂到例如 `/mnt/secrets-store` 这样的目录后，容器会看到以 `objectName` 命名的文件；官方 database credentials 示例中，`dbUsername` 与 `dbPassword` 两个对象最终分别成为 `/mnt/secrets-store/dbUsername` 与 `/mnt/secrets-store/dbPassword` 两个文件。

如果应用只能从环境变量读取配置，可以在 `SecretProviderClass` 中增加 `secretObjects`，让 CSI driver 与 provider 流程把读取到的对象同步为 Kubernetes Secret，再由 Pod 使用 `secretKeyRef` 作为环境变量来源。官方示例中，`secretObjects.data[].objectName` 引用下方 `objects` 中的对象别名，`key` 则成为 Kubernetes Secret 中的键名。

使用 Helm 安装时，Vault CSI provider 会与 Vault Agent 运行在同一个 Pod 中，以便为缓存与续期提供支持。官方同时提醒，Vault Agent 无法续期它重启前已经创建的 token；如果 Agent container 停止或重启，当既有 token 到期时，Agent 会撤销相关 lease。这个行为尤其影响动态机密，因为动态 lease 的续期和撤销直接关系到后端账号或证书的生命周期。

CSI provider 自身也有 token 缓存参数：`-cache-size` 默认值为 `1000`，表示同一节点上每个挂载机密的 Pod 会缓存一枚 Vault token；设置为 `0` 会禁用缓存，并强制每次 volume mount 请求都重新向 Vault 认证。这个缓存边界是“Pod 挂载请求产生的 Vault token”，不应误解为任意 KV 静态读取都会被长期同步到本地。

认证层面，Vault provider 会以正在挂载 CSI volume 的 Pod 的 ServiceAccount 身份登录 Vault，支持 Kubernetes auth method 与 JWT auth method；该 ServiceAccount 必须绑定到一个 Vault role，且该 role 关联的 policy 必须允许读取目标机密。官方建议为应用 Pod 使用专用 ServiceAccount，以避免应用获得超出自身需求的机密访问面。

---

## 3. 安装前提与 Helm 安装路径

官方安装文档列出三个 Kubernetes 前提：control plane 与 worker node 均为 Kubernetes 1.16 或更高版本，且为 Linux-only；Secrets Store CSI driver 已安装；Kubernetes API server 提供 `TokenRequest` endpoint，该能力需要 `--service-account-signing-key-file` 与 `--service-account-issuer` 参数，并在 Kubernetes 1.20 起以及多数托管集群中默认可用。

安装 Vault Secrets Store CSI provider 的推荐方式是 Vault Helm chart。若要安装新的 Vault 实例并同时启用 CSI provider，需要先添加 HashiCorp Helm 仓库，并使用 Vault Helm chart 0.10.0 或更高版本；启用 CSI provider 的关键值是 `csi.enabled=true`。官方给出的最小命令是 `helm install vault hashicorp/vault --set="csi.enabled=true"`。

需要注意，官方在 Helm 安装示例旁标注：这个命令也会安装 Vault server 与 Agent Injector。因此，本教程建议在生产集群中执行前，结合已有 Vault 部署形态、命名空间规划和准入控制策略调整 Helm values，而不是把示例命令原样套用到已有集群。

升级已有安装时可以使用 `helm upgrade`，但官方建议在任何 install 或 upgrade 前先执行 Helm 的 `--dry-run` 检查变更。可通过 `helm inspect values hashicorp/vault` 查看可用 values；安装文档特别提到，常用 values 包括限制 Vault CSI provider 运行的 namespace、TLS 选项等。

OpenShift 环境有单独要求：需要 OpenShift 4.14 或更高版本，需要 Red Hat 提供的 Secrets Store CSI driver operator，并且需要创建 `secrets-store.csi.k8s.io` 的 `ClusterCSIDriver` 实例。由于 Vault CSI provider 需要 `hostPath` mount access，安装前还要把 `vault-csi-provider` ServiceAccount 加入 `privileged` security context constraint。

---

## 4. Provider 参数与 `SecretProviderClass` 字段

Vault Secrets Store CSI provider 的大多数设置可以通过三层来源配置，优先级从低到高依次是环境变量、命令行参数、`SecretProviderClass` 参数。通过 Helm chart 安装时，provider 命令行参数可以用 `csi.extraArgs` 传入，例如 `--set "csi.extraArgs={-debug=true}"`。

命令行参数分为几类：调试与运行参数包括 `-debug`、`-endpoint`、`-health-addr`、`-version`；缓存与完整性参数包括 `-cache-size` 与 `-hmac-secret-name`；Vault 连接参数包括 `-vault-addr`、`-vault-mount`、`-vault-namespace` 以及 CA、SNI、client certificate、client key、skip verify 等 TLS/mTLS 相关参数。

`-vault-addr` 是 provider 默认连接的 Vault 地址，也可由 `VAULT_ADDR` 环境变量指定。官方强烈建议只在安装 Helm chart 时设置 Vault 地址；如果在 `SecretProviderClass` 中设置 `vaultAddress`，Vault Secrets Store CSI provider 会绕过 Helm chart 为 provider 安装的 Vault Agent cache。由于这个 Agent cache 用于 caching and renewals，本教程建议在生产中谨慎评估是否要在单个 `SecretProviderClass` 中覆盖 Vault 地址。

`SecretProviderClass` 的 Vault 参数中，`roleName` 指定登录 Vault 时使用的 role；`vaultAuthMountPath` 与 `vaultKubernetesMountPath` 都可指定认证挂载路径，并且二者互斥，挂载点可以是 Kubernetes auth mount，也可以是 JWT auth mount；`audience` 会通过 Kubernetes `TokenRequest` API 为请求 Pod 生成带自定义 audience 的 ServiceAccount token，并且如果 Vault role 配置了 audience，两边必须匹配。

`objects` 是最重要的数组参数。每个对象的 `objectName` 是对象别名并同时决定文件名；`method` 默认是 `GET`，支持 `GET` 与 `PUT`；`secretPath` 是 Vault 路径，`GET` 读取时可以在路径上追加 URI 参数，例如 KV v2 的 `?version=1`；`secretKey` 指定从响应中抽取哪个字段，如果省略，则整个 Vault 响应会以 JSON 写入文件。

对象还可以设置 `filePermission` 与 `encoding`。`filePermission` 控制写入文件的权限，默认值是 `0o644`；`encoding` 默认是 `utf-8`，并支持 `hex` 与 `base64` 解码。对于需要向 Vault 发送请求体的场景，可以使用 `secretArgs`；官方提醒，`secretArgs` 作为 HTTP request body 发送，因此只对 HTTP `PUT` 或 `POST` 一类请求有效，例如 PKI 证书生成；如果是 HTTP `GET`，额外参数应写在 `secretPath` 的 URI 参数中。在该 provider 的 `method` 字段中，官方列出的支持值仍是 `GET` 与 `PUT`。

![SecretProviderClass 中 provider、roleName、vaultAddress、vaultAuthMountPath、audience 与 objects 字段共同决定一次挂载请求如何登录 Vault、读取路径并生成文件](/images/ch7-csi/secretproviderclass-fields.png)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；画一张夹在木板上的“SecretProviderClass”表格清单，表格格子分别写着“provider: vault”、“roleName”、“vaultAddress”、“vaultAuthMountPath”、“audience”、“objects”。旁边有三盒彩色文件夹：“objectName = 文件名”、“secretPath = Vault 路径”、“secretKey = 抽取字段”。一只手拿着 ServiceAccount token 印章在表格上盖章。专业词汇保持 English，其他说明使用中文。

---

## 5. 两种消费模式：挂载文件与同步 Kubernetes Secret

第一种消费模式是文件挂载。官方示例使用 database secrets engine 生成动态数据库用户名与密码，并在 `objects` 中把 `database/creds/db-app` 响应里的 `username` 与 `password` 分别映射为 `dbUsername` 与 `dbPassword` 两个文件。Pod 只需要把 CSI volume 挂载到 `/mnt/secrets-store`，容器启动后就能在该目录中读取这两个文件。

第二种消费模式是在文件挂载之外额外同步 Kubernetes Secret。官方示例在同一个 `SecretProviderClass` 中增加 `secretObjects`，把 `dbUsername` 映射到 Kubernetes Secret 的 `username` 键，把 `dbPassword` 映射到 `password` 键；应用容器随后通过 `env[].valueFrom.secretKeyRef` 引用这个 Kubernetes Secret，把值注入为 `DB_USERNAME` 与 `DB_PASSWORD` 环境变量。

需要把这两种模式的责任边界分清楚：CSI provider 的基本产物是挂载到 Pod 文件系统中的文件；环境变量模式并不是 provider 直接修改容器环境，而是先把对象同步为 Kubernetes Secret，再由 Kubernetes 的常规 `secretKeyRef` 机制注入环境变量。即使采用环境变量模式，官方示例仍然让 Pod 通过 CSI volume 引用同一个 `SecretProviderClass`；示例说明该 Pod 挂载 CSI volume 后，机密会挂载到 `/mnt/secrets-store`，同时额外创建 Kubernetes Secret 并由 `secretKeyRef` 引用。

![文件模式把 Vault 响应写进 /mnt/secrets-store；环境变量模式先通过 secretObjects 同步 Kubernetes Secret，再由 secretKeyRef 注入容器环境](/images/ch7-csi/csi-sync-secret-boundary.png)

绘图提示词：手绘风格真实事物比喻，钢笔线绘，水彩淡色阴影；画同一个厨房里两条取料路线。左边路线是“CSI volume”传送带直接把“secret file”小罐子送到“/mnt/secrets-store”货架；右边路线是“secretObjects”登记员把同样的小罐子登记成“Kubernetes Secret”账本，然后“secretKeyRef”服务员把账本里的值放进“environment variables”杯子。专业词汇保持 English，其他说明使用中文。

---

## 6. 选型提示：什么时候选择 CSI provider

如果团队希望使用 Kubernetes 原生的 CSI volume 模型，让应用通过文件读取机密，并且希望这一模式可以与不同厂商的 Secrets Store provider 保持一致，那么 Vault Secrets Store CSI provider 是合适的选择。它把 Vault 接入点约束在 Pod volume 声明与 `SecretProviderClass` 上，应用代码通常不需要理解 Vault API。

如果应用必须使用环境变量，CSI provider 也可以通过同步 Kubernetes Secret 支持这一模式；但这意味着机密会进入 Kubernetes Secret 对象，并被后续的 `secretKeyRef` 消费。本教程建议团队在采用该模式前，结合 Kubernetes etcd 加密、RBAC、审计与 Secret 生命周期策略决定是否允许这种物化形式。

CSI provider 的官方描述集中在 Pod 创建并请求 CSI volume 时读取 Vault 机密，并在 `ContainerCreation` 阶段写入 volume。这说明它的核心语义是按 Pod 的 CSI volume 挂载流程提供机密；官方在本页并未把它描述为持续协调控制器模型。后续 7.6 与 7.7 会讨论 Vault Secrets Operator，它更接近“由平台控制器持续协调 Vault 数据与 Kubernetes 对象”的声明式同步模型。

---

## 7. 互动实验

本节实验是对官方安装路径与 `SecretProviderClass` 文件挂载模式的本地改编：官方文档支持安装 Secrets Store CSI driver、通过 Vault Helm chart 启用 `csi.enabled=true`，以及让 Pod 通过 `SecretProviderClass` 挂载 Vault 机密；Killercoda 单节点环境、Vault dev server 与 KV v2 数据准备属于本教程实验设置。

实验步骤基于官方认证说明与两个官方示例设计：文件挂载与 `secretObjects` 同步有官方示例支撑；检查组件状态、CRD，以及用未绑定 ServiceAccount 触发失败，是本教程用于观察边界的实验设计。实验分为四步：第一步检查 CSI driver、Vault CSI provider 与 `SecretProviderClass` CRD；第二步创建文件挂载示例并读取 `/mnt/secrets-store` 下的文件；第三步故意使用未绑定到 Vault role 的 ServiceAccount 触发挂载失败，观察 ServiceAccount 与 Vault role 的边界；第四步用 `secretObjects` 把同一份 Vault 数据同步为 Kubernetes Secret，再用 `secretKeyRef` 注入环境变量。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-csi" title="实验：用 Secrets Store CSI Driver 与 Vault Provider 挂载机密" />