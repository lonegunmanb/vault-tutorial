---
order: 73
title: 7.3 Vault Proxy：API 代理、缓存与应用身份边界
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.3 Vault Proxy：API 代理、缓存与应用身份边界

> **核心结论**：Vault Proxy 是运行在应用附近的 client daemon。它把应用请求先接入本地 listener，再根据配置把请求转发到真实 Vault server；如果启用了 Auto-auth，Proxy 可以在请求没有 token 时附加自己的 Auto-auth token，或在 `force` 模式下强制覆盖请求自带 token；如果启用了 cache，它还可以在严格边界内缓存新建 token、由受管 token 生成的 leased secrets，以及显式开启后的 KV static secrets。

本节与 [5.6 轻量级代理服务指令](/ch5-vault-proxy) 的侧重点不同：5.6 主要解释 `vault proxy -config=...` 命令、配置块与排错命令；本节从应用接入角度讨论 Proxy 放在什么位置、最终使用哪一个身份访问 Vault、缓存何时可信，以及 Kubernetes 中 persistent cache 应如何理解。

参考文档：

- [What is Vault Proxy?](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy)
- [Use Vault Proxy as an API proxy](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/apiproxy)
- [Vault Proxy caching overview](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/caching)
- [Use built-in persistent caching - Vault Proxy](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/caching/persistent-caches)
- [Use Kubernetes persistent cache - Vault Proxy](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/caching/persistent-caches/kubernetes)
- [Risks of using inconsistent versions of Proxy and Vault](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/versions)

---

## 1. Proxy 解决的应用接入问题

应用直接调用 Vault API 时，通常要先完成认证，取得 client token，再用该 token 读取机密或申请动态凭据；这会把认证、续期、重试和凭据保存逻辑带入应用代码。Vault Proxy 的目标，是用更简单、可扩展的方式帮助应用集成 Vault：应用把请求交给 Proxy，Proxy 再转发给 Vault，并可选择使用自身通过 Auto-auth 得到的 token。

Proxy 的核心能力可以拆成三层：`auto_auth` 负责自动认证并管理本地取得的动态机密相关 token 续期；API proxy 负责把 listener 收到的请求转发给 Vault API；cache 负责缓存新建 token 响应，以及由这些新建 token 生成的 leased secrets 响应，并管理这些 token 与 lease 的续期。

这也解释了 Proxy 与 Agent 的分工：Agent 更适合模板渲染和进程供给，Proxy 则专注于 API 代理、Auto-auth token 注入和缓存。若应用已经能够发起 Vault HTTP 请求，但不希望自己处理登录和续期，Proxy 往往比模板文件更贴合这个接入形态。

![Vault Proxy 位于应用和 Vault server 之间，应用只连接本地 listener，Proxy 负责 Auto-auth、cache 和 API proxy](/images/ch7-vault-proxy/proxy-application-boundary.png)

---

## 2. 最小运行拓扑：`vault`、`listener` 与 `api_proxy`

Proxy 配置文件最少要回答两个问题：真正的 Vault server 在哪里，以及应用请求从哪里进入 Proxy。前者由顶层 `vault` block 描述，常见字段包括 `address`、TLS CA、client certificate、SNI server name、namespace，以及嵌套的 `retry` 设置；后者由一个或多个 `listener` block 描述。

`listener` 的 `role` 默认是 `default`，会同时服务 API proxy 和 metrics；若设为 `metrics_only`，该 listener 只暴露 metrics，不作为 Vault API 代理入口。只要 listener 没有被设为 `metrics_only`，它就会把请求代理到 `vault` block 指向的 Vault server；如果同时配置了 `cache` block，API proxy 会先尝试让 cache 子系统处理符合条件的请求，再转发给 Vault。

`require_request_header = true` 是 listener 层的安全开关，它要求进入该 listener 的请求必须带有 `X-Vault-Request: true`；缺少该请求头时，Proxy 会返回 HTTP `412: Precondition Failed`。官方文档将这个选项描述为抵御 Server Side Request Forgery 的额外保护层，但它不能替代网络隔离、TLS、最小权限 policy 或应用边界设计。

Proxy 可以通过 `vault proxy -config=/etc/vault/proxy-config.hcl` 启动；`-config` 可以指向单个文件、多次指定多个文件，也可以指向一个目录并在运行时组合目录内配置。该命令通常在应用所在虚拟机、容器或 Pod 附近运行。

---

## 3. Auto-auth token 的三种请求身份结果

理解 Proxy 的第一条主线，是理解最终访问 Vault 的 token 来自哪里。默认情况下，`api_proxy.use_auto_auth_token` 为 `false`，Proxy 不会替应用注入自身 Auto-auth token；请求若需要访问受保护 API，仍然应携带调用者自己的 Vault token。

当 `use_auto_auth_token = true` 时，未携带 Vault token 的请求会由 Proxy 附加 Auto-auth token 后转发；如果请求已经携带 token，则请求自带 token 优先生效，Proxy 不会覆盖它。这个模式适合允许“应用可以无 token 访问，也可以显式提交自己的 token”的场景，但必须明确最终身份可能因请求是否带 token 而改变。

当 `use_auto_auth_token = "force"` 时，Proxy 会忽略请求中已有的 Vault token，强制使用自身 Auto-auth token。这个模式能让某个应用的所有请求稳定落在同一条 Vault 身份边界内，但也意味着应用请求中的 `X-Vault-Token` 不再决定 Vault 侧身份。

官方文档特别强调：只要使用 Proxy 的 Auto-auth token，就强烈建议一个应用对应一个 Proxy，因为多个应用共用同一个 Auto-auth token 时，Vault 无法区分这些请求分别来自哪一个应用。若必须让多个应用共享同一个 Proxy，官方建议保持 `use_auto_auth_token = false` 的默认行为。

`api_proxy` 还提供 `prepend_configured_namespace`。当 Proxy 自身配置了 namespace，并启用该选项时，Proxy 会把配置的 namespace 前置到请求 namespace header 上；例如 Proxy 配置 `ns1`，请求带 `ns2`，最终会访问 `ns1/ns2`。这一能力适合明确把 Proxy 固定在某个 namespace 及其子 namespace 内。

![use_auto_auth_token 的 false、true 与 force 三种身份结果：不注入、缺 token 时注入、强制覆盖](/images/ch7-vault-proxy/auto-auth-token-modes.png)

---

## 4. Cache 不是“所有响应都本地保存”

Proxy cache 的基础能力，是缓存包含新建 token 的响应，以及缓存由这些新建 token 生成的 leased secrets 响应，并由 Proxy 负责这些 token 和 lease 的续期。这里的“leased secrets”通常指动态凭据这类带 lease 的响应；普通请求不会因为出现 `cache {}` 就无条件变成本地缓存。

动态 token 与 leased secrets 的缓存只在特定条件下发生：token 创建请求要经过 Proxy，并且新 token 的 parent token 已由 Proxy 管理，或新 token 是 orphan token；leased secret 创建请求也要经过 Proxy，并且使用的 token 已由 Proxy 管理。换言之，缓存边界跟“请求是否经过 Proxy”以及“token 是否由 Proxy 管理”直接相关。

Static secret caching 是另一类能力。启用 `cache_static_secrets = true` 后，Proxy 可以缓存 KV v1 与 KV v2 static secrets；Proxy 只会把缓存响应返回给有权访问该 secret 的 token，因此同一条 KV secret 的多次请求可以只把第一次转发给 Vault。启用 static secret caching 还要求配置 Auto-auth，并确保 Auto-auth token 有权限订阅 KV events，因为 Proxy 要通过事件订阅判断何时更新缓存中的 secret。

Proxy 判断“重复请求”的方式，是把 HTTP request、所有 headers 和 request body 序列化后计算 hash，并用该 hash 作为缓存索引。这意味着请求参数顺序或 header 细节变化可能导致 cache miss，即使业务含义看起来相同；教学和生产代码都应使用稳定的请求生成方式，减少不必要的重复缓存条目。

缓存驱逐也有清晰边界。动态 secret 到达最大 TTL 或续期失败时，对应缓存会被驱逐；经由 Proxy 转发且成功的 token revoke 与 lease revoke 请求，也会触发相关缓存条目的 best-effort 驱逐。若撤销绕过 Proxy 直接发生在 Vault server 上，Proxy 可能暂时不知道，因此可能出现 stale cache entries。

为处理这类 stale cache 场景，Proxy 提供 `/proxy/v1/cache-clear` API。该 API 可按 `request_path`、`lease`、`token`、`token_accessor` 或 `all` 清理缓存；即使某个 listener 没有启用缓存，该 API 仍可返回 `200`，只是没有实际缓存需要清理。

---

## 5. `cache` 配置与续期责任

只要配置文件中出现顶层 `cache` block，就会启用 cache 子系统；但如果既没有启用 `cache_static_secrets`，又禁用了动态 secret 缓存，cache 将没有实际工作可做。官方文档还强调，配置 `cache` block 时必须同时定义 listener，否则没有入口可以使用缓存。

`disable_caching_dynamic_secrets` 的默认值为 `false`，表示动态 secret 缓存默认没有被禁用；`cache_static_secrets` 的默认值为 `false`，表示 KV static secret caching 必须显式开启。把这两个选项放在一起看，可以避免误把空 `cache {}` 理解为“所有 KV 读取都会被缓存”。

Proxy 使用 Vault Go API 提供的 Renewer 来续期 tokens 和 leases；默认 cache 运行在内存中，不持久化到存储。Proxy 关闭后，续期操作会立即停止；这并不等于这些 secrets 被撤销，只是仍然有效且尚未撤销的 tokens 和 leases 不再由该 Proxy 负责续期。

下面的配置片段展示了一个最小 API proxy 与 cache 组合。它只适合本地教学或被严格限制的测试环境；生产环境应启用 TLS listener、限制 listener 暴露范围，并为 Auto-auth role 绑定最小权限 policy。

```hcl
vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/proxy-role-id"
      secret_id_file_path                 = "/root/proxy-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

cache {}

api_proxy {
  use_auto_auth_token = "force"
}

listener "tcp" {
  address                = "127.0.0.1:8100"
  tls_disable            = true
  require_request_header = true
}
```

---

## 6. Kubernetes persistent cache 的正确边界

Persistent cache 用来从前一个 Vault Proxy 进程创建的 cache file 中恢复 tokens、leases 和 static secrets。该 cache file 是 BoltDB 文件，包含由生成的 encryption key 加密的 tuples；这些 encrypted tuples 包括用于取回 secrets 的 Vault token、tokens 或 secrets 的 leases，以及 secret values。

使用 persistent cache 必须启用 Auto-auth。恢复缓存时，如果 Auto-auth token 已经过期，缓存会被 invalidated，相关 secrets 需要重新从 Vault 取回。这个限制提醒我们：persistent cache 不是绕过 Vault 生命周期的长期离线 secret 仓库，而只是跨 Proxy 进程交接续期状态的辅助机制。

官方文档明确说明，Vault Proxy persistent cache 当前只支持 Kubernetes 环境。配置时可以使用 `persist "kubernetes" { path = "/vault/proxy-cache" }`，也可以在 `cache.persist` 的通用配置中设置 `type = "kubernetes"`、`path`、`keep_after_import`、`exit_on_err` 和 `service_account_token_file`。

当 persistent cache type 为 `kubernetes` 时，Proxy 会针对 Kubernetes 优化该 cache，并要求能够读取 Kubernetes ServiceAccount token。这个 ServiceAccount token 会在 cache 加密与解密时作为额外 integrity check 使用；默认路径是 `/var/run/secrets/kubernetes.io/serviceaccount/token`，也可以通过 `service_account_token_file` 覆盖。

Kubernetes persistent cache file 只应作为 initialization Proxy container 与 sidecar Proxy container 之间交接 Vault tokens 和 leases 的文件使用，并应通过 memory volume 在两个 Proxy containers 之间共享。这一点非常重要：它不是给多个 Pod 长期共享 secret values 的持久卷，也不是替代 Kubernetes Secret、CSI volume 或 VSO 的平台级同步机制。

![Kubernetes 中 init container 先创建 persistent cache file，sidecar Vault Proxy 通过 memory volume 接续 tokens 和 leases](/images/ch7-vault-proxy/kubernetes-persistent-cache-handoff.png)

---

## 7. 版本不一致时的风险判断

Vault Proxy 与 Vault server 不要求运行完全相同的版本；不同版本组合是被允许的，但如果 Proxy 或 server 没有同时升级，可能无法使用最新功能。Proxy 检测到自身与 Vault server 版本不一致时，会在日志中写入提示，这个提示用于帮助排查可能由版本差异引发的问题。

当 Proxy 版本早于 Vault server 时，多数 Vault server 升级会保持向后兼容；如果存在不兼容变更，官方会在 Vault upgrade guide 中说明。此时，Proxy 构建后才新增的 auth methods 不可用，已有 auth methods 通常应继续工作；而 API proxy 只是镜像传入请求，所以即便请求使用的是 Proxy 编译时尚不存在的 endpoint，通常也不会妨碍 Proxy 转发该请求。

当 Proxy 版本新于 Vault server 时，如果 Proxy 依赖旧 server 不具备的功能，就可能无法工作；官方会尽量把新能力做成 opt-in 并提供 graceful degradation，但并非所有情况都能降级。对纯 API proxy 而言，不兼容通常不太可能直接体现在请求转发本身，但新功能可能不可用。

因此，生产排错时应把版本差异作为背景信息，而不是第一时间视为根因。更稳妥的顺序是先确认 listener 是否接收请求，再确认 Auto-auth 是否成功，再确认最终 token 的 policy 是否允许目标路径，最后再结合 Proxy 日志中的版本提示判断是否涉及新功能兼容问题。

---

## 8. 观测、关闭 API 与安全注意事项

Proxy 支持 telemetry stanza，并采集认证成功和失败、代理成功、Vault 返回错误、代理失败、cache hit 与 cache miss 等指标。这些指标有助于把问题拆分为“认证失败”“Vault 拒绝”“Proxy 转发失败”和“缓存未命中”等不同层次。

Proxy 还提供 `/proxy/v1/quit` 关闭端点，但默认禁用，必须在 listener 的 `proxy_api` block 中显式开启。官方文档提示该端点不需要授权，因此只应在可信接口上启用；普通应用代理 listener 不应随意暴露这个端点。

收到 `SIGHUP` 后，Proxy 会尝试重新加载 listener TLS configuration，也会把日志级别更新为配置文件中指定的值。这使得证书刷新和日志级别调整可以在不重启 Proxy 进程的情况下完成，但配置语法、端口变更与身份策略仍应按变更流程审慎验证。

从安全设计角度看，Proxy 不会消除 Vault policy 的重要性。无论请求是否经过 Auto-auth token 注入，Vault 最终仍根据到达 server 的 token 做授权判断；因此，每个 Proxy 使用的 Auto-auth role 都应只拥有该应用所需的最小 capabilities，并通过 listener 暴露范围、TLS、请求头保护和一应用一 Proxy 的部署边界共同收束风险。

---

## 9. 互动实验

本节配套实验会在同一台 Vault dev server 上部署两个 Proxy：一个使用 `use_auto_auth_token = true`，另一个使用 `use_auto_auth_token = "force"`。学员会亲自观察无 token 请求、低权限 token 请求、强制覆盖 token、`X-Vault-Request` 请求头保护、`/proxy/v1/cache-clear` 管理 API，以及 Kubernetes persistent cache 配置模型之间的区别。

- **Step 1**：阅读 AppRole、policy 与 `use_auto_auth_token = true` 的 Proxy 配置，并启动第一个 Proxy。
- **Step 2**：对比 `true` 与 `force` 两种模式下，请求自带 token 是否会覆盖 Auto-auth token。
- **Step 3**：调用 cache-clear API，理解 cache 的边界、清理入口和日志观察方法。
- **Step 4**：阅读 Kubernetes persistent cache 配置片段和 Pod 清单，明确 memory volume、init container 与 sidecar Proxy 的交接关系，并完成版本排错清单。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-vault-proxy" title="实验：Vault Proxy 身份边界、缓存清理与 Kubernetes persistent cache 模型" />