---
order: 57
title: 5.7 轻量级代理服务指令：vault proxy 的配置文件解析与进程调试
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.7 轻量级代理服务指令：vault proxy 的配置文件解析与进程调试

> **核心结论**：`vault proxy` 用同一个 Vault 二进制启动一个靠近应用运行的代理守护进程。它通过本地 listener 接收应用请求，再把请求转发到真正的 Vault 服务端；如果配置了 Auto-auth，还可以由 Proxy 自动登录、续期并向被代理请求附加 token，从而减少应用直接管理 Vault token 的负担。

本节面向已经掌握 Vault 基础 CLI 的学习者，目标不是替代完整的应用集成课程，而是先把 `vault proxy -config=...` 这条命令背后的配置结构、请求转发路径、Auto-auth token 使用方式、缓存边界和进程调试方法讲清楚。

相关官方文档包括：[What is Vault Proxy?](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy)、[Use Vault Proxy as an API proxy](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/apiproxy)、[Auto-authentication](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth)、[Auto-auth with AppRole](https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/approle)、[Vault Proxy caching overview](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/caching)。

---

## 1. Vault Proxy 的定位

Vault Proxy 的设计目的，是降低应用接入 Vault 时必须先完成认证、保存 token、续期 token、再调用 Vault API 的复杂度。它运行在应用附近，可以让应用把本地 Proxy 当作 Vault API 入口，由 Proxy 负责把请求转交给远端 Vault。

从功能边界看，Proxy 主要由三部分能力组成：Auto-auth、API proxy 和 caching。Auto-auth 用配置好的认证方法自动取得并续期 token；API proxy 通过 listener 接收 Vault API 请求并转发；caching 可以缓存新建 token 的响应以及由这些 token 生成的带租约动态机密响应，并管理这些 token 与 lease 的续期。

Vault Agent 与 Vault Proxy 都支持 Auto-auth，也都能缓存新建 token 与 lease；差异在于 Agent 支持模板渲染和进程监督，而 Proxy 的重点是 API 代理。官方能力对比表明确把 Agent 的 API proxy 标为 deprecated，把 Proxy 的 API proxy 标为支持状态，因此新的 API 透明代理场景应优先使用 Proxy。

可以把 Proxy 理解为“应用门口的凭证代办窗口”：应用把 Vault API 请求交给本地窗口，窗口知道真正的 Vault 地址，也知道怎样代表应用登录并使用合适的 token。这个比喻只用于帮助理解；在真实系统中，Proxy 仍然是一个需要严格配置监听地址、权限策略和网络边界的进程。

![Vault Proxy 位于应用与 Vault 服务之间，代办认证并转发 API 请求](/images/ch5-vault-proxy/proxy-request-flow.png)

---

## 2. 最小配置由哪些部分组成

Proxy 配置文件通常从 `vault`、`auto_auth`、`api_proxy`、`cache` 和 `listener` 这些顶层块开始。`vault` 指明远端 Vault 服务地址和 TLS 连接参数；`auto_auth` 指明如何登录以及 token 写入哪里；`api_proxy` 控制代理请求如何使用 Auto-auth token；`cache` 启用缓存子系统；`listener` 指明 Proxy 在本机或套接字上监听哪些请求。

`vault` 块最多只能有一个。常见字段包括 `address`、`ca_cert`、`ca_path`、`client_cert`、`client_key`、`tls_skip_verify`、`tls_server_name` 和 `namespace`；其中 `address` 可以被 `VAULT_ADDR` 覆盖，`namespace` 的优先级从低到高依次是配置文件、`VAULT_NAMESPACE` 环境变量、`-namespace` 命令行选项。

`vault` 块内部还可以配置 `retry`。`num_retries` 默认语义是最多重试 12 次，设为 `-1` 表示禁用重试，`VAULT_MAX_RETRIES` 环境变量会覆盖配置文件中的值；需要注意的是，Auto-auth 有自己的重试机制，不受这个 `retry` 块控制。

`auto_auth` 由 method 与 sink 两部分组成。method 描述 Proxy 应使用哪种 Vault 认证方法取得 token；sink 描述取得或更新 token 后写到哪里。官方文档强调，认证成功后 Auto-auth 会把 token 写入所有配置正确的 sink，并会自动续期未被 wrapping 的认证 token，直到 Vault 拒绝续期。

在教学实验中，AppRole 是最容易观察的 Auto-auth 方法之一。AppRole auto-auth 会从文件读取 `role_id` 和 `secret_id`，发送给 Vault 的 AppRole auth method；`role_id_file_path` 是必填项，`secret_id_file_path` 是可选项，`remove_secret_id_file_after_reading` 默认会在读取后删除 secret ID 文件，可显式设为 `false` 便于实验反复启动。

`api_proxy` 的关键字段是 `use_auto_auth_token`。当它设为 `true` 时，请求本身没有 Vault token，Proxy 会附加 Auto-auth token；如果请求已经带有 token，则请求自带 token 会优先生效。当它设为字符串值 `"force"` 时，Proxy 会忽略请求中已有的 Vault token，强制使用 Auto-auth token。

官方文档特别提醒：当使用 Proxy 的 Auto-auth token 转发请求时，强烈建议一个应用对应一个 Proxy，因为 Vault 无法区分多个应用通过同一个 Proxy 使用同一枚 Auto-auth token 发出的请求。若多个应用共享一个 Proxy，通常应保持 `use_auto_auth_token = false` 的默认行为。

`listener` 块决定 Proxy 对外接收请求的位置。Proxy 支持一个或多个 listener；listener 可以与 cache 一起使用，并会启用 API proxy。除标准 listener 配置外，Proxy listener 还支持 `require_request_header`、`role` 和 `proxy_api` 等字段。

`require_request_header = true` 要求进入该 listener 的请求必须带有 `X-Vault-Request: true` 头；缺少该头时，Proxy 会返回 `412: Precondition Failed`。官方文档说明，这个选项可为服务器端请求伪造攻击提供额外防护层。

---

## 3. 启动命令与日志选项

启动 Proxy 的基本命令是 `vault proxy -config=/etc/vault/proxy-config.hcl`。同一个 `-config` 标志可以指向单个配置文件，也可以多次出现以组合多个配置文件，还可以指向一个目录并在运行时组合目录中的配置。

如果需要查看命令帮助，可以执行 `vault proxy -h`。常用命令行日志选项包括 `-log-level`、`-log-format`、`-log-file`、`-log-rotate-bytes`、`-log-rotate-duration` 和 `-log-rotate-max-files`；其中日志级别支持 `trace`、`debug`、`info`、`warn`、`error`，日志格式支持 `standard` 与 `json`。

`-log-file` 接受绝对路径。路径以分隔符结尾时，默认文件名为 `proxy.log`；路径没有扩展名时，默认加 `.log`；发生轮转时，Proxy 会在文件名中加入当前时间戳。`-log-rotate-duration` 默认 24 小时，`-log-rotate-max-files` 默认 0，表示旧日志永不自动删除，设为 `-1` 表示新日志生成时丢弃旧日志。

Proxy 也支持把这些日志选项写入配置文件，例如 `log_level`、`log_format`、`log_file`、`log_rotate_duration`、`log_rotate_bytes` 和 `log_rotate_max_files`。官方文档说明，收到 `SIGHUP` 后，Proxy 会按配置文件更新日志级别，并尝试重新加载 listener 的 TLS 配置，从而可以在不中断进程的情况下刷新证书或调整日志级别。

---

## 4. API 代理请求如何流动

当 listener 的 `role` 不是 `metrics_only` 时，它会作为 Vault API 的代理入口，把请求转发到 `vault` 块配置的 Vault 服务端。如果同时配置了 `cache`，API proxy 会先尝试让缓存子系统处理符合条件的请求，然后再把请求转发到 Vault。

最需要区分的是 `use_auto_auth_token = true` 与 `use_auto_auth_token = "force"`。前者只在请求没有 Vault token 时使用 Auto-auth token；后者即使请求已经带有 `X-Vault-Token`，也会改用 Proxy 自己的 Auto-auth token。这一差异直接决定应用是否还能用自己的 token 覆盖 Proxy 的身份。

在训练环境中，使用 `"force"` 可以让学员清楚看到“应用不再直接决定 Vault 身份”的效果；在生产环境中，则必须把这个能力与“一应用一 Proxy”的部署边界配套使用，并让 Auto-auth token 只拥有该应用所需的最小权限。

![use_auto_auth_token true 与 force 的差异：请求是否自带 token 会改变最终身份](/images/ch5-vault-proxy/auto-auth-token-modes.png)

---

## 5. 缓存能力的边界

Proxy caching 的基本目标，是缓存包含新建 token 的响应，以及由 Proxy 管理的 token 生成的带租约动态机密响应，并由 Proxy 管理这些 token 与 lease 的续期。这个能力适合减少重复认证和动态凭据生成的压力，但不等于把所有 Vault 响应都自动变成本地缓存。

只要配置文件中出现顶层 `cache` 块，就会启用缓存子系统；但如果 `cache_static_secrets` 不是 `true` 且 `disable_caching_dynamic_secrets` 不是 `false`，缓存不会实际发挥作用。官方文档还说明，定义 `cache` 块时必须同时定义 listener，否则没有入口可以使用缓存。

动态机密缓存条目在 Proxy 无法继续续期时会被驱逐，例如达到最大 TTL 或续期失败。Proxy 还会尽力观察 token revoke 与 lease revoke 请求，在这些请求成功转发后驱逐相关缓存；但如果撤销直接发生在 Vault 服务端而没有经过 Proxy，Proxy 可能暂时不知道，因此文档提供了 `/proxy/v1/cache-clear` 端点用于手动清理缓存。

静态 KV 缓存是一个更高阶能力。官方缓存文档说明，静态 KV 缓存默认关闭，启用时需要配置 Auto-auth，并确保 Auto-auth token 有权限订阅 KV 事件；同时 Agent/Proxy 总览页提示，部分特性例如 static secret caching 只有连接到 Vault Enterprise 服务器时才可用。因此，本节实验只演示缓存子系统的存在与清理 API，不把静态 KV 缓存作为开源基础实验前提。

---

## 6. 进程观测与安全开关

`pid_file` 可以把 Proxy 进程 ID 写入指定文件，便于脚本发送信号或检查进程。`exit_after_auth = true` 会让 Proxy 在一次成功认证并把 token 写入所有 sink 后以 0 退出，这适合只想取 token 的一次性流程，不适合作为长期 API 代理运行。

`disable_idle_connections` 与 `disable_keep_alives` 可针对 `auto-auth` 和 `proxying` 禁用空闲连接或 keep-alive，也可分别通过 `VAULT_PROXY_DISABLE_IDLE_CONNECTIONS` 和 `VAULT_PROXY_DISABLE_KEEP_ALIVES` 环境变量配置；环境变量会覆盖配置文件中的值。

Proxy 支持 telemetry 配置，并采集 `vault.proxy.auth.failure`、`vault.proxy.auth.success`、`vault.proxy.proxy.success`、`vault.proxy.proxy.client_error`、`vault.proxy.proxy.error`、`vault.proxy.cache.hit`、`vault.proxy.cache.miss` 等运行指标。这些指标可用于区分认证失败、Vault 返回错误、Proxy 转发失败和缓存命中情况。

Proxy 还提供 `/proxy/v1/quit` 关闭端点，但默认禁用，必须在 listener 的 `proxy_api` 中显式启用。官方文档特别提醒，该端点不需要授权，因此只应在可信接口上启用；普通应用代理 listener 不应随意开放这个端点。

---

## 7. 教学实验配置示例

下面的配置与本节互动实验一致：Vault dev server 监听在 `127.0.0.1:8200`，Proxy 监听在 `127.0.0.1:8100`，Auto-auth 使用 AppRole 文件方式取得 token，file sink 把取得的 token 写入 `/root/proxy-token`，API proxy 强制所有被代理请求使用 Auto-auth token。

```hcl
pid_file = "/tmp/vault-proxy.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
  retry {
    num_retries = 3
  }
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

  sink {
    type = "file"
    config = {
      path = "/root/proxy-token"
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

此配置只适合本地教学环境。生产环境应优先使用 TLS listener，严格限制 listener 暴露范围，避免使用过宽的 Vault policy，并根据应用边界决定是否允许或强制使用 Auto-auth token。

---

## 8. 常见排错路径

如果 Proxy 无法启动，首先用 `vault proxy -h` 确认当前 Vault 二进制支持 proxy 子命令，再检查 `-config` 指向的是文件、多个文件还是目录。随后查看 Proxy 日志，确认 `vault.address` 是否可达、AppRole 文件是否存在、listener 端口是否被占用。

如果请求返回 412，应检查 listener 是否启用了 `require_request_header`，并确认请求是否带有 `X-Vault-Request: true`。这个错误并不表示 Vault policy 拒绝访问，而是 Proxy 在请求到达 Vault 前就拒绝了请求。

如果请求返回 403，应查询 Auto-auth token 的 policy 和请求路径是否匹配。尤其在 `use_auto_auth_token = "force"` 时，请求中自带的 `X-Vault-Token` 不会决定最终身份，最终权限来自 Proxy 的 Auto-auth token。

`/proxy/v1/cache-clear` 是 Proxy 自己的管理 API。判断它是否成功时，先看 `curl` 返回的 HTTP 状态码；看到 `200 OK` 就表示请求成功。Proxy 日志主要用于确认 Auto-auth 是否成功，以及普通 Vault API 请求是否经过 `api_proxy` 转发，不要把“日志里没有 cache-clear 行”当成失败。

如果观察到缓存没有命中，应先确认请求属于 Proxy 可缓存范围。动态机密和 token 缓存依赖通过 Proxy 创建并由 Proxy 管理的 token 或 lease；普通 KV 读取不会因为出现空 `cache {}` 块就自动成为静态机密缓存实验。

---

## 9. 互动实验

本节配套了一个完整的 Killercoda 实验，学员将在真实 Vault dev server 上完成 AppRole Auto-auth、Proxy 启动、请求头保护、强制使用 Auto-auth token、缓存清理 API 和日志排错的练习。

- **Step 1**：查看预置 AppRole、最小权限 Policy 和 Proxy 配置文件。
- **Step 2**：启动 `vault proxy`，确认 Auto-auth 成功并写入 sink token。
- **Step 3**：通过 Proxy 读取 KV 机密，验证 `X-Vault-Request` 与 `use_auto_auth_token = "force"`。
- **Step 4**：调用 cache-clear API，用状态码确认结果，再结合日志区分 Auto-auth、API proxy 转发、412 与 403。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-vault-proxy" title="实验：Vault Proxy 配置、Auto-auth 与 API 代理" />
