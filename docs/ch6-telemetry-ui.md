---
order: 68
title: 6.8 核心指标遥测（Telemetry）暴露与可视化 UI 界面底层配置
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.8 核心指标遥测（Telemetry）暴露与可视化 UI 界面底层配置

> **核心结论**：`telemetry` 与 `ui` 是 Vault 配置文件中两个相对独立、却共同决定"运维人员能不能看到 Vault 内部状态"的顶层块。`telemetry` 块负责把 Vault 内部产生的各项度量（metrics）发布到上游观测系统；`ui` 块负责开关内置的浏览器图形界面。本节按"`telemetry` 块的总体角色 → 各类公共参数与 sink 选型 → Prometheus 拉取式接入的端点机制 → `listener` 子块中的 `telemetry` 子配置（未授权指标访问） → `ui` 块本身与它对 `listener` 的依赖"五段顺序展开，最后以一个动手实验把 Prometheus 拉取链路与 UI 访问链路都跑通。

本节是第 6 章配置文件深入系列的第七节。在 6.6 节"HA 模式"与 6.7 节"服务注册"分别解决了"客户端找到活跃节点"与"外部系统知道节点状态"之后，本节解决的是再上一层的"运维人员看到节点内部到底发生了什么"——前者是数据面的可达性，本节是控制面的可观测性。

---

## 1. `telemetry` 块的角色：把内部度量发布给上游观测系统

`telemetry` 是 Vault 配置文件中的一个顶层块（stanza），其唯一职责是把 Vault 内部产生的各项度量发布到一个或多个上游系统；可发布的具体指标清单维护在官方文档的 "Telemetry internals" 页面，而本节只覆盖与配置块本身相关的内容。

`telemetry` 块的参数按"上游系统类型"分组，每一类上游系统在文档里对应一个独立子小节（如 `prometheus`、`statsd`、`statsite`、`dogstatsd`、`circonus`、`stackdriver`），另外还有一组对所有 sink 都生效的"公共参数（Common）"。

> **必须澄清的常见误解**：从遥测端点取到的指标是**节点本地**的——绝大多数时候真正有价值的是当前活跃 leader 节点的指标，尤其是在节点刚启动的阶段；并且某些指标（例如 `vault.identity.*` 相关的 active 月度统计）**只**由 leader 节点上报。这意味着观测系统在抓取多节点集群时必须有意识地区分"节点级指标"与"集群级指标"，不能把所有节点的同名指标无差别相加。

![Vault 节点内部度量经由 telemetry 块发布到 Prometheus / statsd / Stackdriver 等上游系统的整体拓扑示意，强调"度量本地产生、由配置选择推送或被拉取"](/images/ch6-telemetry-ui/telemetry-overview.png)

---

## 2. 公共参数与各类 sink：从"采样口径"到"目的地"的配置维度

### 2.1 公共参数：先决定"采什么、采得多细"

`telemetry` 块的公共参数控制的是采样口径，与最终发往哪类上游系统无关。最值得熟悉的几项包括：`usage_gauge_period`（默认 `"10m"`，控制高基数用量类指标——例如 token、entity、secret 计数——的采集周期，置为 `"none"` 可完全关闭这类采集）；`maximum_gauge_cardinality`（默认 `500`，限定 gauge 标签的最大基数）；`disable_hostname`（默认 `false`，控制是否在 gauge 值上前缀本机 hostname）；`enable_hostname_label`（默认 `false`，控制是否给所有指标都附加一个 `host` 标签，官方建议同时开启 `disable_hostname` 以免重复）；`metrics_prefix`（默认 `"vault"`，统一指标前缀）。

与租约（lease）观测密切相关的还有 `lease_metrics_epsilon`（默认 `"1h"`，决定 `vault.expire.leases.by_expiration` 指标按多大时间桶聚合即将过期的租约——例如设为 `1h` 时，25 分钟后过期的租约 A 与 35 分钟后过期的租约 B 会因四舍五入而落入不同的桶）、`num_lease_metrics_buckets`（默认 `168`，决定该指标总共上报多少个时间桶——结合 1 小时的桶宽即覆盖未来一周）、以及 `add_lease_metrics_namespace_labels`（默认 `false`，开启后会按命名空间维度再切一刀，但会显著放大指标基数）。

`add_mount_point_rollback_metrics` 是一个必须特别留意的开关：默认 `false` 时，Vault 上报的是 `vault.rollback.attempt` 与 `vault.route.rollback` 两条不带挂载点名的聚合指标；开启后才会按每个挂载点拆分上报为 `vault.rollback.attempt.{MOUNT_POINT}` 等形式。该参数自 Vault 1.15 起默认关闭，原因正是这类按挂载点拆分的指标基数过高、容易拖垮观测后端。

`filter_default`（默认 `true`，在没有任何过滤规则时是否放行所有指标——置 `false` 且无规则即等于完全静默）与 `prefix_filter`（一组形如 `["+vault.token", "-vault.expire", "+vault.expire.num_leases"]` 的规则数组，前缀加号放行、减号屏蔽，遇到重叠时以更具体的规则为准、屏蔽优先于放行）共同构成了"按前缀粗筛"的过滤机制，是降低观测后端写入压力的第一道闸门。

### 2.2 sink 选型：推送式 vs. 拉取式

按上游协议形态可以把 `telemetry` 支持的 sink 分为两类：

- **推送式（push）**：Vault 进程主动把指标按周期写到外部端点。代表是 `statsd`（参数 `statsd_address`，写入一台 statsd 服务器）、`statsite`（参数 `statsite_address`，写入一台 statsite 服务器）、`dogstatsd`（参数 `dogstatsd_addr`，并可通过 `dogstatsd_tags` 给所有上报包附上形如 `"my_tag_name:my_tag_value"` 的标签）、`circonus`（一组 `circonus_*` 参数对接 Circonus HTTPTRAP check）、以及 `stackdriver`（一组 `stackdriver_*` 参数对接 Google Cloud Monitoring，需要服务账号具备 `roles/monitoring.metricWriter` 角色）。
- **拉取式（pull）**：Vault 不主动外发，而是把指标暂存在自身内存中，等待 Prometheus 从 `/v1/sys/metrics` 端点拉走。配置开关只有一项 `prometheus_retention_time`（默认 `"24h"`，控制指标在内存中的保留时长；置为 `0` 即关闭 Prometheus 遥测）；官方同时建议开启 `disable_hostname` 以免指标名被前缀 hostname。

![statsd 等推送式 sink 由 Vault 主动外发，Prometheus 拉取式 sink 由观测端定时来抓的对比示意](/images/ch6-telemetry-ui/sink-push-vs-pull.png)

---

## 3. Prometheus 接入：`/v1/sys/metrics` 端点的访问规则

由于 Prometheus 走拉取式接入，理解 `/v1/sys/metrics` 端点本身的几条访问规则比理解 `prometheus_retention_time` 更重要。

第一条规则关于"哪个节点会响应"：`/v1/sys/metrics` 默认只在活跃节点上可访问，并在待命节点上自动禁用。一个必须分清的关键细节是：待命节点**永远不会**把对 `/v1/sys/metrics` 的请求"转发（forward）"给 leader（这与 6.6 节讲到的对其它 API 的请求转发行为不同）；而在未开启未授权指标访问时，开源版 Vault 的待命节点会以 HTTP "重定向（redirect）"的方式把客户端引导到 leader 节点（开启之后则改为就地返回自身指标，详见下一节 §4）。

第二条规则关于"返回什么格式"：客户端必须在请求头中设置 `Accept: prometheus/telemetry` 或 `Accept: application/openmetrics-text` 二者之一，端点才会返回 Prometheus 文本格式；多数 Prometheus 服务器在抓取时会自动带上这类 Accept 头。

第三条规则关于"鉴权"：访问 `/v1/sys/metrics` 需要一个对该路径同时具备 `read` 与 `list` 能力的 Vault token；在 Prometheus 抓取作业里，应使用其 `bearer_token` 或 `bearer_token_file` 选项把 token 注入到 scrape 请求。

第四条规则关于"路径"：Vault 没有使用 Prometheus 默认的 `/metrics` 路径，因此 Prometheus 端必须显式设置 `metrics_path: "/v1/sys/metrics"`，否则会抓到 404。一份能直接落地的最小 Prometheus job 配置示例如下：

```yaml
scrape_configs:
  - job_name: 'vault'
    metrics_path: "/v1/sys/metrics"
    scheme: https
    tls_config:
      ca_file: your_ca_here.pem
    bearer_token: "your_vault_token_here"
    static_configs:
      - targets: ['your_vault_server_here:8200']
```

对应在 Vault 端，最小可工作的 `telemetry` 块仅需两行：

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
```

---

## 4. `listener` 子块中的 `telemetry`：未授权指标访问

需要严格区分两个**同名但作用域不同**的 `telemetry` 块——上文 §1\~§3 介绍的是顶层 `telemetry` 块（配置 sink 与采样行为），而 `listener "tcp"` 内部还有一个名为 `telemetry` 的子块，其当前唯一的参数是 `unauthenticated_metrics_access`（默认 `false`），置为 `true` 时该 listener 上的 `/v1/sys/metrics` 端点允许**未授权访问**。

它的典型配置形式如下，开启后 Prometheus 抓取作业不再需要 bearer token，但代价是任何能连到该 listener 的网络主体都能读到指标，**应通过网络隔离或反向代理鉴权来弥补这一暴露面**：

```hcl
listener "tcp" {
  telemetry {
    unauthenticated_metrics_access = true
  }
}
```

结合 §3 的第一条规则，这个开关还有一个常被忽视的副作用：开启后，**待命节点不再把请求重定向到 leader，而是直接返回自身的指标**。这对采集"待命节点本地视角"的指标（如自身资源占用、复制延迟、客户端连接数）至关重要。

![同名 telemetry 块的两个作用域：顶层块决定"采什么、发去哪儿"，listener 子块决定"指标端点的访问门禁"](/images/ch6-telemetry-ui/telemetry-two-scopes.png)

---

## 5. `ui` 块：开关内置图形界面与它对 `listener` 的依赖

Vault 内置一套图形界面（GUI），可在浏览器里完成机密的增删改查、登录、解封等大部分日常操作；该界面**默认未启用**，需要在配置文件中显式设置 `ui = true` 才会激活；客户端进程不需要这个开关，因为客户端不对外提供 UI 服务。

```hcl
ui = true

listener "tcp" {
  # ...
}
```

UI 与 API 共用同一个 `listener` 端口，因此**必须**在配置文件中至少声明一个 `listener` 块，UI 才有暴露面。例如把 listener 绑定到 `10.0.1.35:8200`，UI 即可在 `https://10.0.1.35:8200/ui/` 被访问；若 listener 仅绑定 `127.0.0.1:8200`，则 UI 也只能从本机访问。

关于 TLS：官方推荐为 UI 启用 TLS，且证书必须对所有访问 UI 的 DNS 名以及 SAN 中的 IP 地址都有效；若 Vault 使用自签名证书，浏览器需要安装对应根 CA，否则会显示"不受信任"警告，并提升 MITM 风险。

关于会话超时：UI **不提供**可配置的会话超时，而是复用所登录认证方法对应的 token TTL / lease duration——在活跃使用期间，UI 会在 token 寿命过半时自动续期；当用户对 Vault API 的最近一次请求发生后保持静止超过 3 分钟，UI 会停止自动续期，让 token 自然到期；只要再发起一次 API 请求，自动续期与 3 分钟静止计时都会被重置。需要特别提醒的是，仅在表单中输入文字并不一定触发 API 调用，因此长时间填表也可能让 token 静默过期。

![UI 通过同一个 listener 端口与 API 共享暴露面，浏览器会话受 token TTL 与 3 分钟静止规则共同约束](/images/ch6-telemetry-ui/ui-listener-and-session.png)

---

## 6. 小结

把本节五段配置维度并排放在一起即可形成一张运维清单：

1. 顶层 `telemetry` 块决定**采什么**（公共参数）与**发去哪儿**（sink 选型——推送式或拉取式）；
2. 拉取式接入 Prometheus 时，必须同时满足"只 leader 响应、需要 Accept 头、需要带 read+list 能力的 token、路径必须显式指向 `/v1/sys/metrics`"四条端点规则；
3. `listener.telemetry.unauthenticated_metrics_access` 是**唯一**能让待命节点就地返回自身指标、并免除 token 依赖的开关，但开启后必须以网络隔离弥补暴露面；
4. `ui = true` 才能开启内置 GUI，其暴露面完全由 `listener` 决定，会话超时由 token TTL 与 3 分钟静止规则共同管控。

这四条加起来构成了"运维人员能不能稳定地观察到每一个 Vault 节点内部状态"的最小完备配置面。

---

## 7. 动手实验

本节配套了一个 Killercoda 实验，学员将在单台 Killercoda 主机上启动一个 3 节点 Vault Raft 集群与一台 Prometheus，**亲手把顶层 `telemetry` 块、`listener.telemetry` 子块与 `ui` 开关分别配置上**，并通过 `curl` 与浏览器观察本节正文中的几条核心结论。完成下列练习：

1. 启动并初始化 3 节点集群，仅在配置文件顶层加入最小化的 `telemetry { prometheus_retention_time = "30s" disable_hostname = true }`，先用带 token 的 `curl -H "Accept: prometheus/telemetry"` 直接抓取 leader 的 `/v1/sys/metrics`，验证"只 leader 响应"以及 token 鉴权；
2. 在不带 token 的情况下重复抓取，观察 `403`；再为某一个待命节点的 `listener` 加入 `telemetry { unauthenticated_metrics_access = true }` 并 SIGHUP 重载，验证该节点开始就地返回自身指标；
3. 为顶层块追加 `prefix_filter = ["+vault.token", "-vault.expire"]` 与 `filter_default = true`，对比开启前后抓取响应中带 `vault.expire.` 前缀的指标条数，验证按前缀粗筛的效果；
4. **拉取式接入端到端验证**：在同一台主机上启动一个 Prometheus 进程，按 §3 的最小 job 配置（含 `metrics_path: /v1/sys/metrics`、`bearer_token`、`Accept` 头由 Prometheus 自动带）抓取 leader，等一个 scrape 周期后在 Prometheus 的 `/api/v1/query` 上查询 `vault_core_unsealed`，确认指标确实被拉到了；
5. **推送式接入端到端验证**：在同一台主机上启动一个 `statsd` 兼容的轻量接收端（例如以 TCP/UDP 监听打印每行内容的小脚本），给某个节点追加 `telemetry { statsd_address = "127.0.0.1:8125" disable_hostname = true }` 并 SIGHUP 重载，几十秒后即可在接收端的输出中看到形如 `vault.runtime.alloc_bytes:...|g` 的推送数据，验证 push sink 链路；
6. 为 leader 节点开启 `ui = true`、保持其 listener 监听 `0.0.0.0:8200`，从 Killercoda 提供的浏览器端口入口访问 `/ui/`，用 root token 登录并完成一次机密读写，验证 UI 暴露面与 listener 的绑定关系。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-telemetry-ui" title="实验：开启 Vault 指标遥测与内置 UI 并验证访问规则" />
