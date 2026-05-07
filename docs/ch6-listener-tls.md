---
order: 62
title: 6.2 网络监听器（Listener）与最高级别 TLS 协议族强化配置
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.2 网络监听器（Listener）与最高级别 TLS 协议族强化配置

> **核心结论**：`listener` 块用于声明 Vault 在哪些地址、端口或本地 socket 上接收 API 请求。Vault 默认即启用 TLS 1.2/1.3，必须显式 `tls_disable` 才能退化为 HTTP；正式环境应直接以 TLS 1.3 为最低协议版本，把 TLS 当作不可绕过的强制层而非可选项。

本节是第 6 章配置文件深入系列的第二节，建立在 6.1 节"`storage` 与 `listener` 都是必填顶层块"这一前置事实之上，目标是把 `listener` 块下所有面向生产环境的关键参数讲清楚，并给出当前社区与官方推荐的最高强度 TLS 配置基线。本节也会一并覆盖较少被注意、但在容器化场景中很有价值的 Unix domain socket listener。

> 本节不会展开演示如何申请或签发证书，证书签发本身留到第 3.7 节（PKI 引擎）和第 10.4 节（ACME 自动签发）。本节只关心"已经拿到证书 / 私钥 / CA 之后，如何把它们以最严格的方式喂给 Vault 的 listener"。

---

## 1. `listener` 块在 Vault 配置中的位置

Vault 的 `listener` 块用于声明 Vault 在哪些地址、端口（或 Unix socket）上响应请求；目前 Vault 支持两种 listener 类型，分别是 TCP 与 Unix domain socket。其中 TCP 类型用于通过网络对外暴露 Vault HTTP API，Unix 类型则只面向本机进程通过文件系统路径访问。

一份 Vault 配置文件中可以出现**多个** `listener` 块，例如同时监听本地回环地址和某一张内网网卡，或同时启用一个 TCP listener 与一个 Unix listener。需要注意的是，一旦声明了多个 listener，就必须额外配置顶层的 `api_addr` 与 `cluster_addr`，以便集群其它节点知道应该把请求转发到哪个对外地址。

![Vault 配置文件中 listener 与 storage、api_addr 等顶层块的关系示意图](/images/ch6-listener-tls/listener-stanza-overview.png)

---

## 2. TCP listener 最小骨架与默认监听地址

TCP listener 的最小可写法是 `listener "tcp" { address = "127.0.0.1:8200" }`。`address` 参数声明 Vault 在哪一个地址与端口监听 HTTP API 请求；如果省略，默认值就是 `127.0.0.1:8200`，因此这一最小写法本身即等价于完全省略 `address`。

除了用于客户端 API 请求的 `address`，TCP listener 还有一个独立的 `cluster_address` 参数，用于声明本节点用于接收"集群成员之间"通信的地址。如果没有显式给出，`cluster_address` 默认取 `address` 的端口加 1，例如默认就是 `127.0.0.1:8201`。在多数普通部署里这个参数并不需要显式设置；只有当 Vault 节点之间无法直接互通（例如必须经过 TCP 负载均衡器中转）时，才需要把它显式指定为可被对等节点访问的地址。

`address` 与 `cluster_address` 都支持 [go-sockaddr 模板](https://pkg.go.dev/github.com/hashicorp/go-sockaddr/template) 写法，可在运行时根据实际网卡情况动态求值。这一能力在使用容器编排或自动伸缩时尤其重要：同一份配置文件可以在不同实例上自动解析出各自正确的本地地址。

---

## 3. 在多接口上同时监听

下面的官方示例展示了如何让同一个 Vault 节点同时监听本地回环地址和某一张内网网卡（这里是 `10.0.0.5`），并在顶层显式声明 `api_addr` 与 `cluster_addr` 指向那张内网网卡，以便集群成员之间和外部客户端都能找到本节点。

```hcl
listener "tcp" {
  address = "127.0.0.1:8200"
}

listener "tcp" {
  address = "10.0.0.5:8200"
}

# Advertise the non-loopback interface
api_addr     = "https://10.0.0.5:8200"
cluster_addr = "https://10.0.0.5:8201"
```

如果希望同时在所有 IPv4 与 IPv6 接口上监听（含本地回环），可以把 `address` 写成 `[::]:8200`、`cluster_address` 写成 `[::]:8201`。也可以只绑定到一个具体的 IPv6 地址，例如 `[2001:1c04:90d:1c00:a00:27ff:fefa:58ec]:8200`。

---

## 4. 默认 TLS 行为：协议版本与密码套件

Vault 的 TCP listener **默认就启用 TLS**，并且只接受 TLS 1.2 或 TLS 1.3 的连接，会主动拒绝任何使用 TLS 1.0 或 1.1 的客户端握手请求。这意味着课程中常出现的"裸 HTTP 测试"实际上是开启了 `tls_disable` 之后的退化行为，不能视作 Vault 的默认状态。

Vault 在 TLS 1.3 下默认启用的密码套件为 `TLS_AES_128_GCM_SHA256`、`TLS_AES_256_GCM_SHA384` 与 `TLS_CHACHA20_POLY1305_SHA256` 这一固定集合；在 TLS 1.2 下，默认密码套件还会受到证书类型（RSA 还是 ECDSA）的影响，并由 Go 标准库 `crypto/tls` 与 HashiCorp 的 `tlsutil` 包共同决定具体集合。换言之，TLS 1.3 不允许由用户挑选密码套件，而 TLS 1.2 才需要也才能由用户精细配置。

> 关于 Sweet32（CVE-2016-2183）漏洞：HashiCorp 的官方说明承认，Go 标准库目前仍然保留对 3DES 密码套件的支持，因此一些漏洞扫描工具可能会对 Vault 的默认 TLS 1.2 配置标记 Sweet32 风险；Go 团队已将 3DES 在密码套件优先级中下调，但尚未将其移除。如果合规审计严格要求屏蔽 3DES，应当显式给出不含 3DES 的 `tls_cipher_suites` 列表。

![TLS 1.3 与 TLS 1.2 在密码套件可配置性上的差异示意图](/images/ch6-listener-tls/tls12-vs-tls13-cipher-control.png)

---

## 5. TLS 相关参数全览

下表汇总 Vault TCP listener 中与 TLS 直接相关的全部参数。其中标注 `reloads-on-SIGHUP` 的字段，可以在 Vault 进程接收 `SIGHUP` 信号时被重新加载；其它字段必须重启 Vault 才能生效。

| 参数 | 默认值 | 含义摘要 |
| :--- | :--- | :--- |
| `tls_disable` | `"false"` | 是否禁用 TLS。Vault 默认启用 TLS，必须显式置为 `"true"` 才会回退为 HTTP。 |
| `tls_cert_file` | 必填 | TLS 服务器证书的 PEM 文件路径；若需要包含 CA，应把主证书与 CA 拼接在一起，主证书放在前面。`reloads-on-SIGHUP`。 |
| `tls_key_file` | 必填 | TLS 私钥的 PEM 文件路径；若文件被加密，启动时会提示输入口令，热加载时该口令必须保持一致。`reloads-on-SIGHUP`。 |
| `tls_min_version` | `"tls12"` | 允许的最低 TLS 版本，可选 `tls10` / `tls11` / `tls12` / `tls13`。文档明确警告 `tls10` 与 `tls11` 已被广泛认为不安全。 |
| `tls_max_version` | `"tls13"` | 允许的最高 TLS 版本；同样警告不要使用 `tls10` / `tls11`。 |
| `tls_cipher_suites` | `""` | 逗号分隔的 TLS 密码套件白名单。**只对 TLS 1.2 及更早版本生效**；要让该参数真正发挥作用，必须把 `tls_max_version` 设为 `tls12`，否则会优先协商 TLS 1.3。 |
| `tls_prefer_server_cipher_suites` | `"false"` | **已弃用**。即使设置也不会生效。 |
| `tls_require_and_verify_client_cert` | `"false"` | 启用客户端证书强制校验（mTLS）；要求客户端出示一份能被系统 CA 验证通过的证书。 |
| `tls_client_ca_file` | `""` | 用于校验客户端证书的 CA 文件（PEM）。 |
| `tls_disable_client_certs` | `"false"` | 主动关闭客户端证书请求；与 `tls_require_and_verify_client_cert` 互斥，不能同时为 `true`。 |

> **关于 SIGHUP 与 TLS 配置热加载的边界**：官方关于"如何配置 TLS"的指南在前置假设里明确写道："如果你的 Vault 集群正在运行，必须按照官方步骤进行优雅重启才能让 TCP listener 上的 TLS 变更生效；SIGHUP 不会重载你的 TLS 配置。"这与上文 `tls_cert_file` / `tls_key_file` 的 `reloads-on-SIGHUP` 标注初看似乎矛盾，但这两段叙述说的并不是同一回事：`reloads-on-SIGHUP` 只针对**证书与私钥所对应文件的内容**，例如证书轮换时把新 PEM 写入同一路径并发送 SIGHUP；而其它 TLS 配置项（最低版本、密码套件、是否启用客户端证书等等）的变更则必须重启进程才会被应用。

---

## 6. 强化配置基线一：TLS 1.3 唯一可用

如果你的所有客户端都已经具备 TLS 1.3 支持能力（现代主流编程语言运行时与 `curl` 都早已支持），最简洁、最安全的强化基线是直接把 `tls_min_version` 设为 `"tls13"`，让 Vault 拒绝一切低于 TLS 1.3 的握手。这种做法的额外好处是：你无需再操心 `tls_cipher_suites` 的配置，因为 Vault（实际上是 Go 标准库）只会启用 Mozilla 现代兼容性指南推荐的 TLS 1.3 密码套件，且不接受用户自定义。

```hcl
listener "tcp" {
  address         = "127.0.0.1:8200"
  tls_cert_file   = "cert.pem"
  tls_key_file    = "key.pem"
  tls_min_version = "tls13"
}
```



---

## 7. 强化配置基线二：TLS 1.2 + 显式密码套件白名单

如果客户端兼容性约束要求继续支持 TLS 1.2，应当把 `tls_min_version` 与 `tls_max_version` 都固定为 `"tls12"`（必须同时锁住最高版本，否则 Vault 会优先协商 TLS 1.3，导致密码套件白名单失去意义），并通过 `tls_cipher_suites` 显式列出仅含 ECDHE + AEAD 系列的密码套件。下面是官方给出的、显式排除任何 3DES 密码套件以规避 Sweet32 攻击的 TLS 1.2 强化范例：

```hcl
listener "tcp" {
  address         = "127.0.0.1:8200"
  tls_cert_file   = "cert.pem"
  tls_key_file    = "key.pem"
  tls_min_version = "tls12"
  tls_max_version = "tls12"
  tls_cipher_suites = "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
}
```

`tls_cipher_suites` 列表中的密码套件**优先级顺序由 Go 标准库 `tls` 包决定，而非按照配置文件中的写出顺序生效**。换言之，把 ChaCha20 写在前面也无法强制让 Go 优先协商它。

> **能不能用 `tls_prefer_server_cipher_suites` 反过来强制服务器端优先？答案是不能。** 该参数已被官方明确弃用，即使写在配置文件里也不会生效。

---

## 8. 验证 TLS 配置：使用 `sslscan` 扫描

完成 TLS 配置后，应当在投入生产前用一款外部 SSL 扫描器对实际监听端口进行实测，确认对外协商出的协议版本与密码套件确实符合预期。官方推荐使用开源工具 `sslscan` 进行验证：扫描结果应至少明确显示 `SSLv2`、`SSLv3`、`TLSv1.0`、`TLSv1.1` 处于 disabled 状态，并仅能在 `TLSv1.2`/`TLSv1.3` 上协商出现代密码套件。

```text
$ sslscan 127.0.0.1:8200

  SSL/TLS Protocols:
SSLv2     disabled
SSLv3     disabled
TLSv1.0   disabled
TLSv1.1   disabled
TLSv1.2   enabled
TLSv1.3   enabled
```



值得注意：上述官方示例输出中，使用 RSA 证书时扫描结果**仍然会出现** `TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA` 与 `TLS_RSA_WITH_3DES_EDE_CBC_SHA`，对应前文 Sweet32 风险说明。这恰好印证了"如果合规要求严格屏蔽 3DES，则必须按 TLS 1.2 强化基线显式配置 `tls_cipher_suites`"。

---

## 9. 双向 TLS（mTLS）：把客户端证书也校验起来

`tls_require_and_verify_client_cert = "true"` 会让本 listener 强制执行客户端证书校验：客户端必须出示一份证书，且能被系统 CA 或显式提供的 `tls_client_ca_file` 链路验证通过，否则 TLS 握手直接失败。这是把 Vault 暴露给一个"已有 PKI 内部 CA"的内网时最常见的入门级零信任加固手段。

与之相反的开关是 `tls_disable_client_certs = "true"`，它会让 listener 主动**不**向客户端请求证书。文档明确警告：`tls_disable_client_certs` 与 `tls_require_and_verify_client_cert` 是互斥字段，不能同时为 `true`。在默认配置（两者均为 `false`）下，Vault 会向客户端请求证书但并不强制要求，TLS 客户端校验仍然是可选的而非强制的。

> 仅启用 `tls_require_and_verify_client_cert` 本身并不会让客户端证书被映射成"某个 Vault 用户身份"——它只是 TLS 层的握手强制。要把"客户端证书 = 已认证的 Vault 用户"这一映射建立起来，需要再启用第 4 章的 TLS Cert 认证方法（`vault auth enable cert`）。这部分留到第 4 章对应小节展开。

![Vault listener 上 TLS 相关四个开关之间的状态机：默认请求但不强制 / 强制双向 / 主动关闭客户端证书](/images/ch6-listener-tls/mtls-decision-matrix.png)

---

## 10. HTTP 超时类参数：抵御慢速攻击与超长请求

下面这组参数与 TLS 协议本身无关，但同样直接影响 listener 在面对异常网络流量时的稳健性。它们都使用带后缀的字符串书写，例如 `"30s"`、`"1h"`：

| 参数 | 默认值 | 作用摘要 |
| :--- | :--- | :--- |
| `http_idle_timeout` | `"5m"` | 启用 keep-alive 后，等待下一个请求的最长空闲时间；为 0 时回退为 `http_read_timeout`，再为 0 则使用 `http_read_header_timeout`。 |
| `http_read_header_timeout` | `"10s"` | 读取请求头的最长允许时间。 |
| `http_read_timeout` | `"30s"` | 读取整个请求（含 body）的最长允许时间。 |
| `http_write_timeout` | `"0"` | 写响应的最长允许时间，每读到一个新请求头都会重置；默认 `"0"` 表示永不超时。 |
| `max_request_size` | `33554432`（即 32 MB） | 单个请求允许的最大字节数。设为小于 0 的值表示完全不限制。 |
| `max_request_duration` | `"90s"` | 单个请求允许的最长执行时间，超时后 Vault 会取消该请求；该值会覆盖顶层 `default_max_request_duration`。 |

---

## 11. JSON 解析复杂度限制：抵御 DoS

Vault 在监听层引入了一组针对 JSON 请求体的解析复杂度上限，用于在低资源环境（例如轻量级容器）下抵御通过深度嵌套或庞大字段制造的拒绝服务（DoS）攻击。这些参数的默认值都是"宽松"的，官方明确建议根据自己应用场景与可用资源把它们调小：

| 参数 | 默认值 | 防御目标 |
| :--- | :--- | :--- |
| `max_json_depth` | `500` | JSON 对象最大嵌套深度；防止深度递归导致的栈溢出 / DoS。 |
| `max_json_string_value_length` | `1048576`（1 MB） | 单个字符串值的最大字节数；防止超大字符串耗尽内存。 |
| `max_json_object_entry_count` | `10000` | 单个 JSON 对象允许的键值对数量上限；用于缓解 HashDoS 与一般资源耗尽。 |
| `max_json_array_element_count` | `10000` | 单个 JSON 数组元素数量上限。 |
| `max_json_token` | `500000` | 单个 JSON 载荷允许的总 token 数（key、值、括号等的总数），相当于一个总体复杂度上限。 |

---

## 12. 反向代理与真实客户端 IP：PROXY protocol 与 `X-Forwarded-For`

在生产部署中 Vault 经常被放在 L4 / L7 负载均衡器之后。如果不做额外配置，Vault 看到的源 IP 永远是负载均衡器的 IP，而不是真实客户端 IP，会让审计日志失去溯源价值。Vault 提供了两条互补的还原真实客户端 IP 的途径：PROXY protocol（L4 层）与 `X-Forwarded-For` 头（L7 层）。

PROXY protocol 通过 `proxy_protocol_behavior` 启用，可选取值有：`use_always`（一律使用 PROXY 协议给出的客户端 IP）、`allow_authorized`（仅当源 IP 在 `proxy_protocol_authorized_addrs` 列表中时才信任 PROXY 头）、`deny_unauthorized`（源 IP 不在白名单内则直接拒绝）。除非 `proxy_protocol_behavior` 为 `use_always`，否则必须显式提供至少一个 `proxy_protocol_authorized_addrs` 条目，该字段不允许为空。

`X-Forwarded-For` 通过 `x_forwarded_for_authorized_addrs` 启用：把允许的反向代理源 CIDR 列入该字段后，Vault 才会信任该来源所发的 `X-Forwarded-For` 头并把审计日志中的 `remote_address` 替换为头里的真实客户端 IP。配套字段 `x_forwarded_for_hop_skips` 用于跳过链路尾部若干跳，`x_forwarded_for_reject_not_authorized`（默认 `"true"`）和 `x_forwarded_for_reject_not_present`（默认 `"true"`）则决定遇到不可信来源或缺失头时是否直接拒绝连接。

如果反向代理同时承担 TLS 终止并通过特定 HTTP 头把客户端证书继续传给 Vault（典型场景：反向代理 + TLS Cert Auth Method），还需要配置 `x_forwarded_for_client_cert_header` 与 `x_forwarded_for_client_cert_header_decoders`。后者是按顺序执行的解码器列表，可选值为 `BASE64`、`DER`、`URL`；官方明确给出 Traefik 与 NGINX 两种典型反向代理对应的解码器组合：Traefik 使用 `BASE64`，NGINX 使用 `URL,DER`。

---

## 13. 敏感信息脱敏：未认证端点的"少说话"开关

Vault 有一组无需认证即可访问的端点，例如 `/sys/health`、`/sys/leader`、`/sys/seal-status`，方便外部健康检查与负载均衡器探活；但同时这些端点会回泄露 Vault 版本号、构建日期、集群名、当前主节点 IP 地址等可能被攻击者用于指纹识别或纵深探测的信息。Vault 允许在 listener 层面把这些字段从响应中移除，做成"对所有 API 客户端都生效"的脱敏。

可用的脱敏开关有三个，都是 listener 内部的布尔字段：

| 参数 | 默认值 | 作用 |
| :--- | :--- | :--- |
| `redact_addresses` | `false` | 在响应中把 `leader_address` 与 `cluster_leader_address` 替换为空字符串。 |
| `redact_cluster_name` | `false` | 把 `cluster_name` 字段替换为空字符串（部分接口会直接省略该键）。 |
| `redact_version` | `false` | 把 `version` 与 `build_date` 字段替换为空字符串。 |

启用脱敏后，`vault status` 等命令的输出也会同步受到影响：`Version`、`Build Date`、`HA Cluster` 会显示为 `n/a`，`Active Node Address` 会显示为 `<none>`。这是因为 CLI 与 UI 也是通过这些 API 端点取数据的。

---

## 14. 自定义 HTTP 响应头与 SIGHUP 修改

自 Vault 1.9 起，listener 支持声明 `custom_response_headers` 子块，按 HTTP 状态码维度向响应注入自定义头，常用于注入 `Strict-Transport-Security`、`Content-Security-Policy` 等安全头。键可以是 `default`（对所有状态码生效）、具体状态码（如 `"200"`）或集合状态码（如 `"2xx"`）；当同一头在多档状态码下定义时，**匹配最具体状态码的值生效**。

与配置文件中其它字段不同，自定义响应头的修改可以通过向 Vault 进程发送 `SIGHUP` 信号热加载，无须重启进程。但任何以 `X-Vault-` 开头的自定义头都会被 Vault 拒绝（因为会与内部头冲突），且如果同一个头同时在配置文件与 `/sys/config/ui` API 端点中被定义，**配置文件中的值优先于 API 端点中的值**。

---

## 15. listener 子块：`telemetry` / `profiling` / `inflight_requests_logging`

Vault 有三组与可观测性相关的端点默认要求认证，但运维场景常需要让 Prometheus / 链路追踪等无凭据采集器直接访问。listener 内部分别提供了三个子块来按 listener 粒度放开这一限制：

| 子块 | 字段 | 作用 |
| :--- | :--- | :--- |
| `telemetry { ... }` | `unauthenticated_metrics_access = true` | 允许未认证访问 `/v1/sys/metrics`。 |
| `profiling { ... }` | `unauthenticated_pprof_access = true` | 允许未认证访问 `/v1/sys/pprof`。 |
| `inflight_requests_logging { ... }` | `unauthenticated_in_flight_requests_access = true` | 允许未认证访问 `/v1/sys/in-flight-req`。 |

> 这三个开关属于"以未认证形式公开的 API 范围扩展"，应当只在已经有网络层访问控制（防火墙规则、Service Mesh 授权、私网 Subnet）时才考虑开启；裸暴露在公网上会显著增加被探测与利用的风险。

---

## 16. `chroot_namespace`：把 listener 钉死在某个命名空间

`chroot_namespace` 字段允许把单个 listener "锁定"在指定命名空间下：之后所有从该 listener 进入的请求，其 `X-Vault-Namespace` 头或 CLI `-namespace` 参数中的命名空间路径会被自动追加到 `chroot_namespace` 之后形成完整路径。例如 `chroot_namespace = "admin"` 且请求头 `X-Vault-Namespace = "ns1"` 时，最终命名空间是 `admin/ns1`；若 `chroot_namespace` 指向的顶层命名空间不存在，listener 会以 4XX 错误拒绝所有调用。

> 命名空间（namespace）是 Vault 用于多租户隔离的高级特性，本节不展开其用法；本段仅说明 `chroot_namespace` 这一字段的语义存在，便于读者在阅读完整 listener 参数表时不会感到陌生。

---

## 17. Unix domain socket listener：本机进程间通信的轻量化选择

除 TCP 之外，Vault 还原生支持 Unix domain socket 作为 listener。它的最小写法是：

```hcl
listener "unix" {
  address = "/run/vault.sock"
}
```

Unix listener 的可配置字段比 TCP listener 简单得多，只有四个：

| 参数 | 默认值 | 含义 |
| :--- | :--- | :--- |
| `address` | `"/run/vault.sock"`（必填） | Unix socket 文件的绑定路径。 |
| `socket_mode` | `""`（可选） | Unix socket 文件的访问权限位与特殊模式标志。 |
| `socket_user` | `""`（可选） | Unix socket 文件的所属用户。 |
| `socket_group` | `""`（可选） | Unix socket 文件的所属用户组。 |

下面是一个把 Unix socket 文件权限收紧到 `644`、所属用户与组都设为 `1000` 的官方示例：

```hcl
listener "unix" {
  address      = "/var/run/vault.sock"
  socket_mode  = "644"
  socket_user  = "1000"
  socket_group = "1000"
}
```

Unix listener 也可以与 TCP listener 共存：常见做法是 TCP 监听对外提供集群与远程 API 访问，而 Unix socket 仅供本机的运维脚本、Vault Agent 或 Vault Proxy 使用，避免本机进程间通信走网络栈：

```hcl
listener "unix" {
  address = "/var/run/vault.sock"
}

listener "tcp" {
  address = "127.0.0.1:8200"
}
```

> Unix listener 的最大优势在于：它通过文件系统的 owner / group / mode 三元组天然附带访问控制，可以让本机非 Vault 用户进程"根本无法连上 Vault 的 API"，比 TCP 上"只在 127.0.0.1 监听"更彻底；缺点是不能跨主机访问，因此常用于本机自动化与代理协同，而非作为对外接口。

![Unix domain socket listener 与 TCP listener 在访问控制上的本质差异](/images/ch6-listener-tls/unix-vs-tcp-listener.png)

---

## 18. 推荐的 6.2 节"最高强度"基线总结

把上文要点合并成一份可以直接抄用的、**TLS 1.3 唯一可用 + 启用敏感字段脱敏 + 关闭未认证端点扩展 + 加固 JSON 解析上限** 的 listener 范例：

```hcl
listener "tcp" {
  address       = "0.0.0.0:8200"

  # —— TLS 强化：仅 TLS 1.3 ——
  tls_cert_file   = "/etc/vault.d/tls/full-chain.pem"
  tls_key_file    = "/etc/vault.d/tls/private-key.pem"
  tls_min_version = "tls13"

  # —— 敏感字段脱敏 ——
  redact_addresses    = "true"
  redact_cluster_name = "true"
  redact_version      = "true"

  # —— 慎重收紧 JSON 解析上限（按业务情况调整） ——
  max_json_depth                = 64
  max_json_string_value_length  = 524288     # 512 KB
  max_json_object_entry_count   = 1024
  max_json_array_element_count  = 1024
  max_json_token                = 50000
}
```



---

## 19. 互动实验

本节配套了一个 Killercoda 实验，学员将基于一份预置的非 TLS 配置出发，**亲手把 listener 升级到 TLS 1.3 唯一可用并通过外部扫描器进行验证**，再额外体验"SIGHUP 不会重载 TLS 协议版本变更"这一关键边界。完成下列练习：

- **Step 1**：阅读预置的 `vault.hcl`，识别其中 `listener "tcp"` 块的字段；用 `vault status` 验证当前以 HTTP 暴露。
- **Step 2**：在实验环境中生成一份自签 ECDSA 证书与私钥，写入 listener 中并删除 `tls_disable`，重启 Vault，使用 `curl --cacert ...` 验证 HTTPS 工作正常。
- **Step 3**：把 `tls_min_version` 设为 `"tls13"`，安装 `sslscan` 并扫描 `127.0.0.1:8200`，确认 TLS 1.0/1.1/1.2 全部 disabled。
- **Step 4**：故意先尝试发送 `SIGHUP` 后再观察 `tls_min_version` 的修改并未生效，再用真正的进程重启来印证"TLS 协议版本变更必须重启进程"。
- **Step 5**：追加一个 `listener "unix" {...}` 子块，给 socket 文件设置 `socket_mode = "600"`，用 `curl --unix-socket /run/vault.sock` 直接访问 Vault API，验证 Unix listener 的可达性与文件系统权限隔离效果。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-listener-tls" title="实验：TCP listener TLS 1.3 强化与 Unix socket listener 共存" />
