---
order: 78
title: 7.8 三种 Kubernetes 集成模式选型与本章小结
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.8 三种 Kubernetes 集成模式选型与本章小结

> **核心结论**：选择 Kubernetes 中的 Vault 接入方式时，不应先问“哪一个功能最多”，而应先问三件事：机密最终以什么形态交给应用、Vault 在 Pod 生命周期的哪个时刻被访问、令牌与租约由谁托管。若团队接受以原生 Kubernetes Secret 作为平台内的二级物化对象，通常优先考虑 Vault Secrets Operator (VSO)；若必须使用 CSI volume 模型或正在统一多家 secret store 的挂载标准，优先考虑 Vault Secrets Store CSI provider；若应用需要 Consul Template 风格的复杂模板渲染、需要在同一个 Pod 内由 Agent 持续写入共享内存卷，或正在迁移已有 annotation 工作流，则保留 Vault Agent Injector。

参考：

- [Kubernetes integrations comparison — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/comparisons)
- [Run Vault on Kubernetes — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes)
- [Vault Secrets Operator — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
- [Vault Secrets Operator API Reference — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [Persist and encrypt the Vault client cache — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/sources/vault/client-cache)
- [Vault Secrets Store CSI provider — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi)
- [Vault Secrets Store CSI provider configurations — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi/configurations)
- [Vault Agent Injector — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector)
- [Vault Agent Injector annotations — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector/annotations)

本节是第 7 章 Kubernetes 部分的收束，不安排新的动手实验。读者只需要把 7.4、7.5、7.6 三节已经完成的配置经验带入本节，理解“同样是把 Vault 机密交给 Pod，为什么三种模式的系统后果完全不同”。

---

## 1. 先看三个判断维度

第一条维度是**机密呈现形式**。VSO 的默认路径是把 Vault 中的源机密同步成原生 Kubernetes Secret，应用再用 `secretKeyRef`、`envFrom` 或普通 Secret volume 消费；CSI provider 的基本路径是把 Vault 数据写入 Pod 的 Secrets Store CSI volume，并且可以额外同步为 Kubernetes Secret 以支持环境变量；Agent Injector 则把 Vault Agent 注入 Pod，让 Agent 把机密渲染到共享 memory volume，默认路径为 `/vault/secrets`。这三种“最终产物”的差异，比 YAML 字段差异更重要，因为它直接决定机密是否进入 Kubernetes API 对象、是否随 Pod 生命周期消失、以及应用是否需要按文件方式读取。

第二条维度是**Vault 访问发生的时机**。VSO 是控制器在后台根据 CRD 持续调谐 source 与 destination，Pod 启动时通常只读取已经存在的 Kubernetes Secret；CSI provider 在 Pod 请求 CSI volume 时取密，并且官方明确说明机密会在 `ContainerCreation` 阶段读取和写入 volume，因此这一步完成前 Pod 会被阻塞；Agent Injector 在 Pod `CREATE` 或 `UPDATE` admission 阶段改写 Pod specification，然后由注入的 init container 或 sidecar container 在 Pod 生命周期内完成取密与渲染。

第三条维度是**谁代表应用向 Vault 认证**。VSO 通过 `VaultAuth` 描述认证方式，支持 `kubernetes`、`jwt`、`appRole`、`aws`、`gcp` 等方法；当使用 Kubernetes auth 时，`VaultAuth` 中指定的 ServiceAccount 必须位于消费资源所在命名空间。CSI provider 使用请求挂载 CSI volume 的 Pod 的 ServiceAccount 向 Vault 认证，并支持 Kubernetes 与 JWT auth method。Agent Injector 的主要方式也是使用 Pod 上绑定的 ServiceAccount，并要求该 ServiceAccount 绑定到 Vault role 和有权读取目标机密的 policy；同时它也可以通过 annotations 配置其它 Vault Agent auto-auth 方法。

![三种 Kubernetes 集成的选型坐标：机密呈现形式、Vault 访问时机、认证主体三条轴线共同决定最终方案](/images/ch7-k8s-selection/selection-axes.png)

---

## 2. 选型矩阵：把差异放在同一张表里

下面的矩阵只比较开源教程中最常用的路径：VSO 默认同步到 Kubernetes Secret，CSI provider 按 Pod volume 挂载，Agent Injector 按 Pod 注入 Vault Agent。官方比较页还提到 VSO 可以与 CSI driver 结合形成 ephemeral volume 路径，但该路径涉及额外组件与授权边界，本章不把它作为初学阶段的主线。

| 维度 | Vault Secrets Operator (VSO) | Vault Secrets Store CSI provider | Vault Agent Injector |
| --- | --- | --- | --- |
| 基本架构 | 常驻 controller 监听 CRD，把 Vault source 同步为 destination Kubernetes Secret | Secrets Store CSI driver 在 Pod 请求 volume 时调用 Vault provider | Mutating webhook 改写 Pod spec，注入 Vault Agent init/sidecar |
| 机密呈现形式 | 默认是原生 Kubernetes Secret | 默认是 Pod 内 CSI volume 文件，可选同步为 Kubernetes Secret | `/vault/secrets` 等共享 memory volume 中的文件 |
| 与 Pod 生命周期关系 | destination Secret 独立于 Pod 存在 | 挂载动作随 Pod 创建发生，Pod 启动依赖取密成功 | Agent 容器随 Pod 存在，init 负责预填充，sidecar 可持续渲染 |
| Vault 不可达时的新 Pod 表现 | 已同步 Secret 仍可被新 Pod 读取，但不会获得新的同步、轮换或修复 | 创建新 Pod 时通常会阻塞在取密和 volume 写入阶段 | 新 Pod 需要 webhook、Vault、Kubernetes auth 等链路可用，预填充或运行期渲染会受影响 |
| Vault 负载与资源消耗 | 官方比较中为最低 Vault 负载、低资源消耗，单个 manager 面向集群调谐 | 官方比较中资源消耗低，但 Vault 负载较高，因为倾向于 per-Pod 连接 | 官方比较中 Vault 负载最高，且每个 Pod 增加 sidecar/init 容器资源 |
| 刷新与轮换机制 | `refreshAfter`、lease-aware 刷新、`expiryOffset`、漂移修复与 `rolloutRestartTargets` | volume 创建时取密，Agent 可承担动态 lease caching and renewal，可选同步 Kubernetes Secret | Agent template 负责获取、续期和重新渲染，annotations 可控制静态机密渲染间隔与 Agent cache |
| 模板能力 | 支持 Secret data transformation，适合把同步结果整理成 K8s Secret 字段 | 官方比较中标为不支持 secret data templating | 支持 Consul Template，适合把多条 Vault 响应组合成应用配置文件 |
| 认证方法覆盖 | Kubernetes、JWT、AppRole、AWS、GCP | Kubernetes、JWT | Kubernetes 以及其它 Vault Agent auto-auth 方法 |
| RBAC 与职责分离 | 应用只需读 destination Secret，平台可用 CRD 与 K8s RBAC 分层管理 | Pod ServiceAccount 直接参与取密，职责分离能力较弱 | 以 Pod annotation 和 ServiceAccount 为主，职责分离能力较弱 |
| 适合的默认场景 | 大多数 Kubernetes 原生应用，尤其是接受 K8s Secret 治理并关注扩展性的场景 | 需要 CSI 标准、临时 volume、或多 secret store 统一接入的场景 | 需要复杂模板、迁移既有 injector 方案、或依赖更广泛 auto-auth 方法的场景 |

矩阵中“Vault 不可达时的新 Pod 表现”需要谨慎理解。VSO 并不是让 Vault 变得不重要，而是把应用启动路径与 Vault 读取路径解耦：只要 destination Kubernetes Secret 已经存在，Kubernetes 可以按普通 Secret 方式把它交给新 Pod；但如果源机密在 Vault 中变化、动态凭据到期、证书需要续签，或者原有 Secret 被删除，VSO 仍然需要恢复到 Vault 的连接才能继续调谐。CSI provider 与 Agent Injector 则把取密动作放在 Pod 创建或 Pod 运行链路中，因此扩容、重建和滚动发布更容易受到 Vault 可达性的直接影响。

---

## 3. 决策树：从约束开始，而不是从工具开始

如果平台安全策略允许机密以 Kubernetes Secret 形式存在，并且团队已经具备对 Kubernetes Secret 的 RBAC、etcd 加密、审计和生命周期治理能力，那么应优先从 VSO 开始。原因不是 VSO“更高级”，而是它把 Vault 接入收束成声明式 CRD 与原生 Kubernetes Secret，应用不需要感知 Vault，也不需要在每个 Pod 中增加 sidecar；官方比较也把 VSO 放在低 Vault 负载、低资源消耗、应用间可共享机密、Pod 自动伸缩默认不依赖 Vault 的一侧。

如果策略要求机密不默认写入 Kubernetes Secret，而是只在 Pod 生命周期内以 volume 文件形式出现，应优先比较 CSI provider 与 Agent Injector。CSI provider 更接近 Kubernetes 标准存储接口，适合组织已经采用 Secrets Store CSI driver，或需要在 Vault 之外同时接入其它 secret store 的场景；Agent Injector 更接近 Vault Agent 的能力边界，适合需要 Consul Template 渲染、需要把多条 Vault 响应组合成一个配置文件、或需要使用 Kubernetes/JWT 之外的 Agent auto-auth 方法的场景。

如果工作负载是短生命周期的 Job 或 CronJob，并且已经选择 Agent Injector，就应优先考虑 `vault.hashicorp.com/agent-pre-populate-only: "true"` 的 init-only 形态。官方 annotation 文档明确说明该选项为 true 时不会注入运行期 sidecar，并推荐用于 Job 或 CronJob，以便 Pod 可以干净终止。若同一类短任务只需要读取一份已经同步好的 Kubernetes Secret，那么 VSO 往往更简单；若它需要按 Pod 创建时即时挂载文件，则 CSI provider 也可以作为候选。

如果核心目标是降低 Vault 压力和集群资源消耗，优先选择 VSO。官方性能比较将 VSO 归为最低 Vault 负载，因为它使用 CRD-specific connections 和 cluster-local secret caching，并以单个 manager 面向整个集群；CSI provider 的资源消耗可以较低，但对 Vault 的负载更高，因为它倾向于 per-Pod connections；Agent Injector 则因 per-Pod connections 与 sidecar pattern 被列为最高负载。

如果要同步动态数据库凭据、云临时凭据或 PKI 证书，VSO 仍然可用，但要额外理解租约与缓存。`VaultDynamicSecret` 会根据 Vault 响应中的 lease duration 以及 `renewalPercent` 管理续期或重新生成；`VaultPKISecret` 可以使用 `expiryOffset` 决定证书到期前的续签时点；官方同时强烈建议动态机密场景持久化并加密 Vault client cache，以便重启和升级后继续跟踪并续期已有动态 secret leases。

![从约束出发的决策树：能否接受 Kubernetes Secret、是否要求 CSI volume、是否需要模板能力、是否关注大规模低负载](/images/ch7-k8s-selection/decision-tree.png)

---

## 4. “认证主体 → token 生命周期托管 → 机密物化形式”三段论

第一段是**认证主体**。VSO 的认证主体由 `VaultAuth` 间接定义，常见做法是在应用命名空间放一个专用 ServiceAccount，然后让同命名空间的 `VaultStaticSecret`、`VaultDynamicSecret` 或 `VaultPKISecret` 引用对应的 `VaultAuth`；官方文档强调，使用 Kubernetes auth 时，ServiceAccount 必须位于请求资源所在命名空间，这是为了避免跨命名空间滥用身份。CSI provider 的认证主体就是请求挂载 CSI volume 的 Pod 的 ServiceAccount；Agent Injector 的主要认证主体也是 Pod 绑定的 ServiceAccount。

第二段是**token 生命周期托管**。VSO 在 controller 内部维护 Vault client cache，里面包含代表某个 `VaultConnection` 与 `VaultAuth` 组合的已认证 client、token 与 lease 状态；该 cache 默认不持久化，动态机密场景建议使用 Vault `transit` 加密后持久化到 operator 命名空间的 Kubernetes Secret。CSI provider 通过与 provider 同 Pod 的 Vault Agent 支持 caching and renewals，并且 provider 本身默认最多缓存 1000 枚 Vault token，同一节点上每个挂载机密的 Pod 存一枚；Agent Injector 则由注入的 Vault Agent 承担 auto-auth、续期和模板渲染，必要时可通过 `agent-cache-enable` 开启 Agent cache。

第三段是**机密物化形式**。VSO 把源机密写成 Kubernetes Secret，这让应用在 Kubernetes 视角下最简单，但也要求平台团队认真治理 Secret 的持久化、访问控制和审计；CSI provider 把源机密写入 Pod 的 CSI volume，应用按文件读取，必要时再同步为 Kubernetes Secret 给环境变量使用；Agent Injector 把模板结果写入共享 memory volume，适合文件配置和复杂模板，但每个 Pod 都要承担 Agent 容器带来的资源与生命周期成本。

把三段论连起来看，三种模式的差异就不再混乱。VSO 的主语是“控制器代表某个声明式身份持续同步，并把结果写成 Kubernetes Secret”；CSI provider 的主语是“某个 Pod 在创建 volume 时用自己的 ServiceAccount 取密，并把结果挂载成文件”；Agent Injector 的主语是“webhook 给 Pod 加上 Vault Agent，Agent 在 Pod 内认证并渲染文件”。只要能用这句话复述清楚某个方案，后面的 YAML 字段就只是表达这句话的具体语法。

---

## 5. 初学者最容易误判的边界

第一，创建 `SecretProviderClass` 本身并不等于已经从 Vault 取回机密。官方 CSI 文档描述的触发点是 Pod 请求 CSI volume：Secrets Store CSI driver 看到该 volume 引用 `SecretProviderClass` 后，才把请求交给 Vault provider，并在 `ContainerCreation` 阶段把机密写入 volume。若还配置了 `secretObjects`，同步 Kubernetes Secret 也依赖这个 volume 使用链路，而不是单独创建 `SecretProviderClass` 即刻发生。

第二，Agent Injector 的注解必须写在真正的 Pod specification 上。对于 Deployment、StatefulSet、Job 等上层资源，注解应位于 `spec.template.metadata.annotations`；官方示例特别指出，把注解写在 Deployment 顶层 metadata 是常见错误。这个边界很基础，却直接决定 webhook 是否能在 Pod 创建或更新时看到 `vault.hashicorp.com/agent-inject: "true"`。

第三，VSO 的 instant updates 不是开源版默认能力。官方文档将其标注为 Enterprise 能力，要求 Vault Enterprise 1.16.3 或更高版本，并且还需要给 VaultAuth role 增加 `subscribe` capability 以及 `sys/events/subscribe/kv*` 读取权限。开源版教学应把 `refreshAfter`、HMAC 漂移检测和普通 reconcile 作为基础模型。

第四，VSO 适合降低应用 Pod 与 Vault 的直接耦合，但它不是免维护缓存层。动态凭据的 lease、PKI 证书的到期续签、源机密变化后的同步、destination Secret 被人工改坏后的修复，都依赖 controller 正常运行并能访问 Vault；动态机密还应启用加密持久化 client cache，避免 controller 重启或升级后集中重新签发凭据。

第五，“支持所有 secret engines”不等于“所有模式下都同样好用”。CSI provider 和 Agent Injector 在官方比较中都标为支持所有 Vault secret engines；VSO 的 Vault source 页面也写明支持所有 Vault secret engines，但 VSO 的 CRD 会按静态 KV、动态机密、PKI 等类别拆成不同资源。初学时应先从数据生命周期选择 CRD 或组件，而不是只看“支持”两个字。

---

## 6. 本章收束建议

对于新的 Kubernetes 应用，如果没有强制要求“机密绝不能进入 Kubernetes Secret”，建议把 VSO 作为第一选择。它最贴近 Kubernetes 声明式工作流，应用侧改动最小，Vault 负载与资源消耗也最可控；同时，平台团队可以把 Vault 连接、认证、同步和 rollout restart 都放在 CRD 与 RBAC 管理体系中。

对于已经标准化 Secrets Store CSI driver、需要 vendor-neutral CSI volume、或明确希望机密主要作为 Pod 内文件出现的团队，CSI provider 是更自然的选择。采用它时要记住：Pod 创建路径会依赖 Vault 可达性，应用读取到的是挂载目录中的文件；若为了环境变量同步 Kubernetes Secret，就已经重新进入 Kubernetes Secret 的治理范围。

对于已有大量 Injector annotation、需要 Consul Template 表达能力、或需要 Kubernetes/JWT 之外更多 auto-auth 方式的工作负载，Agent Injector 仍然有明确价值。采用它时要把 per-Pod Agent 容器资源、Pod 创建时的 webhook 依赖、Vault 与 Kubernetes auth 的连通性、以及 Job/CronJob 的 init-only 设置一并纳入设计。

最后，不必把三种集成理解为彼此排斥的阵营。同一个集群可以让普通业务使用 VSO，把少数必须走 CSI volume 的服务交给 CSI provider，并保留 Injector 服务于需要模板渲染或正在迁移的应用。真正需要避免的是让同一个工作负载同时被多套机制写入同一份配置来源，因为这样会让认证主体、刷新节奏和故障边界变得难以解释。

本章到这里完成了从本机 Agent、独立 Proxy 到 Kubernetes 三件套的应用接入路径。后续进入安全审计与系统观测时，应继续沿用本节的三个问题：谁在认证、谁托管 token 和 lease、机密最终被物化到哪里。只有把这三件事说清楚，审计日志、RBAC、网络策略和故障演练才有明确对象。
