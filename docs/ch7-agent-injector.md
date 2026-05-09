---
order: 74
title: 7.4 Kubernetes 集成模式之一：Vault Agent Sidecar Injector（vault-k8s）
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.4 Kubernetes 集成模式之一：Vault Agent Sidecar Injector（vault-k8s）

> **核心结论**：Vault Agent Injector 不是新的机密引擎，也不是应用 SDK，而是 Kubernetes 的 Mutating Webhook Controller。它在 Pod 创建或更新时读取 Pod metadata annotations；如果工作负载由 Deployment、Job、StatefulSet 等上层资源创建，这些注解就应写在 Pod template 上。Injector 会把 Vault Agent init container、sidecar container、共享内存卷和必要的配置挂载注入到 Pod spec 中，使业务容器可以从本地文件读取 Vault 机密，而不必在应用代码中直接调用 Vault API。

参考：

- [Vault Agent Injector — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector)
- [Vault Agent Injector annotations — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector/annotations)
- [Install Vault Agent Injector — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector/installation)
- [Vault Agent Injector examples — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector/examples)

---

## 1. Injector 的定位：用 Admission Webhook 改写 Pod

Vault Agent Injector 的实现来自 `vault-k8s` 项目，官方文档将它描述为 Kubernetes Mutation Webhook Controller；它会拦截 Kubernetes 中的 Pod `CREATE` 与 `UPDATE` 事件，解析事件中的 metadata annotation，并在发现 `vault.hashicorp.com/agent-inject: true` 时按其它注解改写 Pod specification。

这意味着 Injector 的工作边界位于 Kubernetes API server 的 admission 阶段：Pod 创建时会在调度运行前完成 mutation；Pod 更新时也会先经过 webhook 判断是否需要改写。业务镜像本身不需要内置 Vault SDK，也不需要知道如何调用 Vault 登录 API；它只需要按约定读取被注入到本地文件系统中的文件。

在资源形态上，Injector 会为机密文件准备共享 memory volume。默认情况下，该 volume 会挂载到 Pod 中所有容器，并用于 `/vault/secrets`；如果设置 `vault.hashicorp.com/agent-inject-containers`，则只挂载到指定容器。Vault Agent 容器会把渲染后的机密写入这里，业务容器再从同一路径读取文件。

![Kubernetes API server 把带有 Injector annotation 的 Pod 请求交给 Mutating Webhook，Webhook 返回 patch，最终 Pod 中出现 Vault Agent init container、sidecar container 与 `/vault/secrets` 共享内存卷](/images/ch7-agent-injector/webhook-mutation-flow.png)

---

## 2. 上层资源的注解必须写在 Pod template 上

Injector 在 Pod `CREATE` 或 `UPDATE` 请求中读取 Pod metadata annotations。官方示例特别提醒，一个常见错误是把注解写在 Deployment、Job 或 StatefulSet 这类上层资源自己的 metadata 上；在使用这些上层资源时，注解必须写进 `spec.template.metadata.annotations`，因为真正被创建和变更的是 Pod template。裸 `Pod` 资源则直接把注解写在自己的 `metadata.annotations` 下。

下面这个片段只展示注解所在位置。注意 `metadata.annotations` 位于 `spec.template` 下面，而不是 Deployment 顶层 metadata 下面。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "webapp"
        vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/web"
    spec:
      serviceAccountName: webapp
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
```

当需要给已经存在的 Deployment 增加注解时，可以用 Kubernetes patch 更新 Pod template；官方示例说明 patch 应写入 `spec.template.metadata.annotations`，并且应用 patch 后 Pod 会被重新调度。

---

## 3. 最小注解契约：开关、角色、机密路径与模板

最小可用配置通常由四类注解组成：`vault.hashicorp.com/agent-inject` 打开或关闭注入；`vault.hashicorp.com/role` 指定 Vault Agent auto-auth 登录时使用的 Vault role；`vault.hashicorp.com/agent-inject-secret-<unique-name>` 指定要读取的 Vault 路径；`vault.hashicorp.com/agent-inject-template-<unique-name>` 可选地指定如何把响应渲染成文件。

`<unique-name>` 既是 secret annotation 与 template annotation 的配对键，也是默认输出文件名。官方文档说明，`vault.hashicorp.com/agent-inject-secret-foo: database/roles/app` 会渲染到 `/vault/secrets/foo`；如果写成 `agent-inject-secret-foo.txt`，则会渲染到 `/vault/secrets/foo.txt`。该名称只能包含字母、数字、`.`、`_` 或 `-`。

如果没有提供自定义模板，Injector 会使用 generic template，把 secret 响应中的键值渲染为多行文本；如果提供模板，则模板注解必须使用与 secret 注解相同的 `<unique-name>`。模板语法来自 Consul Template，默认左右分隔符为 `&#123;&#123;` 与 `&#125;&#125;`。

KV v2 的业务数据位于 `.Data.data` 下，因此读取 `secret/data/web` 这类路径时，模板中通常写成 `&#123;&#123; .Data.data.username &#125;&#125;` 或 `&#123;&#123; .Data.data.password &#125;&#125;`。官方文档在 Injector 页面中明确提醒，KV 这类以 map 保存的数据可以通过 `.Data.data.<NAME>` 访问。

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "webapp"
vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/web"
vault.hashicorp.com/agent-inject-template-config.txt: |
  &#123;&#123;- with secret "secret/data/web" -&#125;&#125;
  username=&#123;&#123; .Data.data.username &#125;&#125;
  password=&#123;&#123; .Data.data.password &#125;&#125;
  &#123;&#123;- end &#125;&#125;
```

![一组 `agent-inject-secret-config.txt` 与 `agent-inject-template-config.txt` 注解像一张订单，unique name `config.txt` 同时决定读取路径、模板配对和输出文件名](/images/ch7-agent-injector/annotation-to-file-contract.png)

---

## 4. 认证链路：ServiceAccount、Vault role 与 policy

使用 Injector 时，主要认证方式是 Pod 绑定的 Kubernetes ServiceAccount。官方文档说明，Kubernetes authentication 要求该 ServiceAccount 被绑定到一个 Vault role，而这个 role 再关联到允许读取目标机密的 Vault policy。

不要把课程实验中的“能直接使用 default ServiceAccount”误解为生产建议。官方文档明确指出，使用 Kubernetes auth method 时必须存在 ServiceAccount，并且不建议把 Vault role 绑定到没有显式指定 ServiceAccount 时自动分配给 Pod 的 default ServiceAccount。

认证相关注解也可以覆盖默认行为。`vault.hashicorp.com/auth-type` 默认是 `kubernetes`，`vault.hashicorp.com/auth-path` 默认是 `auth/kubernetes`；如果要让 Agent 使用 AppRole 等其它 auto-auth 方法，则需要通过 `auth-type`、`auth-path`、`auth-config-*` 和 `agent-extra-secret` 等注解提供额外参数与文件。

`vault.hashicorp.com/service` 可以覆盖 Injector 默认配置中的 Vault 地址，值可以指向同一 Kubernetes 集群中的 Vault Service，也可以指向外部 Vault URL。若 Vault 使用 TLS，可以用 `tls-secret` 挂载包含 CA、客户端证书和密钥的 Kubernetes Secret 到 `/vault/tls`，再用 `ca-cert`、`client-cert` 与 `client-key` 指定对应文件路径；`tls-server-name` 用于指定校验服务端证书时使用的名称。`tls-skip-verify` 虽然存在，但官方明确不建议在生产环境中设为 true。

---

## 5. init container 与 sidecar container 的生命周期差异

Injector 可以注入两类 Vault Agent 容器，并且二者都可以通过注解调整。init container 会在业务容器启动之前预先把请求的机密写入共享 memory volume；sidecar container 会在 Pod 运行期间继续认证并把机密渲染到同一位置。

默认情况下，`vault.hashicorp.com/agent-pre-populate` 为 true，也就是会包含 init container 以预填充共享内存卷。`vault.hashicorp.com/agent-pre-populate-only` 设为 true 时，只注入 init container，不再注入运行期 sidecar；官方文档特别说明，这种模式推荐用于 `CronJob` 或 `Job`，以确保 Pod 可以干净终止。

如果 Pod 已经有其它 init container，可以用 `vault.hashicorp.com/agent-init-first` 控制 Vault Agent init container 是否排在最前面。这个开关适用于其它 init container 需要先读取已预填充机密的场景，默认值为 false。

Sidecar 模式的代价是每个被注入的 Pod 都会多出 Agent 容器资源。官方注解文档给出了 Agent 默认资源：CPU limit 默认为 `500m`，memory limit 默认为 `128Mi`，CPU request 默认为 `250m`，memory request 默认为 `64Mi`；同时还提醒，Pod 的 request 和 limit 等于所有容器之和，因此设置 Agent 资源会影响整个 Pod 的调度与容量计算。

运行期 sidecar 关闭时可以选择撤销自己的 token。`vault.hashicorp.com/agent-revoke-on-shutdown` 只作用于 sidecar container，默认 false；`vault.hashicorp.com/agent-revoke-grace` 配置撤销前的宽限时间，默认 `5s`。

![init container 负责启动前预填充，sidecar container 负责运行期持续渲染；init-only 模式适合 Job / CronJob，否则 sidecar 会跟随 Pod 生命周期常驻](/images/ch7-agent-injector/init-sidecar-lifecycle.png)

---

## 6. ConfigMap 高级配置：从注解切换到完整 Agent 配置文件

Injector 有两种配置 Agent 渲染机密的方法：使用 `vault.hashicorp.com/agent-inject-secret` 注解，或者挂载包含 Vault Agent 配置文件的 ConfigMap。官方文档明确说明，这两种方法任一时刻只能使用一种。

当注解无法表达复杂需求时，可以通过 `vault.hashicorp.com/agent-configmap` 指定一个 ConfigMap，Injector 会把其中的配置文件挂载到 `/vault/configs`。该 ConfigMap 必须包含 `config-init.hcl`、`config.hcl` 二者之一或二者全部；`config-init.hcl` 用于 init container，必须设置 `exit_after_auth = true`；`config.hcl` 用于 sidecar container，必须设置 `exit_after_auth = false`。

官方 ConfigMap 示例展示了完整 Agent HCL：其中包括 Kubernetes auto-auth、file sink、`template` destination 以及 Vault 连接参数。这种方式更接近直接运行 Vault Agent，适合需要更细粒度控制模板、sink、TLS 或 auto-auth 参数的团队。

---

## 7. 安装与 TLS：Helm 是推荐路径

官方文档推荐使用 Vault Helm chart 安装和配置 Agent Injector；安装新实例时，先加入 HashiCorp Helm repository，再通过 `helm install vault hashicorp/vault --set="injector.enabled=true"` 启用注入能力。Vault Agent Injector 要求 Vault 版本不低于 1.3.1。

Admission webhook controllers 在 Kubernetes 中运行时需要 TLS。Injector 默认支持 TLS 1.2 及以上，并可通过 `AGENT_INJECT_TLS_MIN_VERSION` 和 `AGENT_INJECT_TLS_CIPHER_SUITES` 配置最低 TLS 版本与 TLS 1.0–1.2 的 cipher suites；官方同时警告 TLS 1.1 及以下通常被认为不安全。

TLS 管理有 Auto TLS 与 Manual TLS 两种方式。默认 Auto TLS 会生成 CA 和 controller 使用的证书/私钥；如果通过 Vault Helm 安装，chart 会自动创建 controller service 的 DNS 项，用于证书校验。Manual TLS 则要求用户提供 server certificate/key 与 base64 PEM encoded CA bundle，也可以与 cert-manager 结合。

Injector 可以运行多个副本。使用 Manual TLS 或 cert-manager 时支持多副本；从 v0.7.0 起，Auto TLS 也支持多副本。Auto TLS 多副本模式下，leader replica 通过名为 `vault-k8s-leader` 的 ConfigMap 确定，并负责生成 CA、patch webhook caBundle、生成并分发 webhook service listener 所需的证书与 key。

默认情况下，Injector 会处理除 `kube-system` 与 `kube-public` 之外的所有 namespace；如果只希望某些 namespace 能被注入，可以通过 namespace selector 匹配 namespace label 来限制作用范围。

---

## 8. 运行约束、排错入口与适用边界

在给 Pod 加注解之前，应先确认三类网络连接可达：Kubernetes API 能连接到 Injector service 的 443 端口且 Injector 能连接 Kubernetes API；Vault 能连接 Kubernetes API；业务 Pod 能连接 Vault。若 Kubernetes 集群启用了 aggregator routing，Kubernetes API 可能会直接连接 Injector service endpoint，此时官方示例特别指出 endpoint 端口是 8080。

Vault 侧也必须先完成 Kubernetes auth method 配置：Kubernetes auth method 应已启用并配置；Pod 应有 ServiceAccount；目标机密应已存在；该 ServiceAccount 应绑定到有权访问目标机密的 Vault role 和 policy。

如果 mutation request 失败，Kubernetes 会把错误附加到 Pod 的 owner 上。Deployment 或 StatefulSet 创建的 Pod 应检查拥有该 Pod 的 ReplicaSet；Job 创建的 Pod 则检查 Job。

Injector 的优势，是在不改业务镜像的前提下把 Vault 机密以文件形式交给容器，并且可以用模板一次组合多条机密；它的代价，是每个被注入的 Pod 里都会多出一到两个 Vault Agent 容器和一块 `/vault/secrets` 共享内存卷——这些容器同样要占用 CPU 和内存（默认 sidecar 即 `250m` CPU、`64Mi` 内存的 request），并被 Kubernetes 计入 Pod 的资源总量，从而抬高单个 Pod 的调度成本和整个集群的容量消耗；启动时还需要满足 Injector、Vault 与 Kubernetes auth 的可达性和配置前提。对于 `Job` 或 `CronJob` 这类短任务，应优先评估 init-only 以避免 sidecar 常驻；对于确实需要运行期持续认证或重新渲染机密的工作负载，再保留 sidecar。

![Injector 的运行边界由三条连接线共同决定：Kubernetes API 到 Injector、Vault 到 Kubernetes API、Pod 到 Vault；每个被注入 Pod 还会增加 Agent 容器资源](/images/ch7-agent-injector/injector-operational-boundaries.png)

---

## 9. 互动实验

本节配套实验使用 Killercoda 提供的 kubeadm 单节点 Kubernetes 环境。实验会用 Helm 安装 Vault dev server 与 Vault Agent Injector，配置 Kubernetes auth method，创建一条 KV v2 机密，再让一个 `busybox` Deployment 通过 Pod template annotations 自动获得 Vault Agent init container、sidecar container 和 `/vault/secrets/config.txt` 文件。

实验还会创建一个 `Job`，通过 `vault.hashicorp.com/agent-pre-populate-only: "true"` 只注入 init container，不注入 sidecar，让学员观察为什么官方建议 Job / CronJob 使用 init-only 模式。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-agent-injector" title="实验：用 Vault Agent Injector 把 Vault 机密注入 Pod 文件" />