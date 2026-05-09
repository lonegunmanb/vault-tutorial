---
order: 72
title: 7.2 Vault Agent：本机模板渲染、令牌托管与进程供给
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.2 Vault Agent：本机模板渲染、令牌托管与进程供给

> **核心结论**：Vault Agent 是运行在应用附近的客户端守护进程。它的现代主线不是继续充当 Vault API 透明代理，而是把认证、令牌续期、模板渲染和必要时的子进程环境变量供给从应用代码中移出，使应用以读取文件或读取环境变量的方式消费 Vault 机密。API proxy 能力虽仍见于配置文档，但官方已经标记为 deprecated；需要 API 代理或静态 KV API 缓存的场景，应转向 Vault Proxy。

参考：

- [What is Vault Agent? — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)
- [Use Vault Agent templates — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template)
- [Run Vault Agent in process supervisor mode — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/process-supervisor)
- [Vault Agent caching overview — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/caching)
- [Use built-in persistent caching — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/caching/persistent-caches)
- [Generate a development configuration file — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/generate-config)
- [Risks of using inconsistent versions of Agent and Vault — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/versions)

---

## 1. Vault Agent 的职责边界

Vault Agent 的设计目标，是降低应用接入 Vault 的初始门槛。对于没有直接集成 Vault SDK 的应用，Agent 可以先代表应用完成认证，再把应用需要的机密渲染成文件；应用只需要读取本地文件，而不必理解 Vault 的登录 API、Token 续期 API 或模板刷新细节。

官方文档将 Agent 描述为一个 client daemon，并列出六类能力：Auto-auth、API proxy、Caching、Windows Service、Templating 和 Process Supervisor Mode。其中 Auto-auth 负责自动认证与令牌续期；Templating 负责使用 auto-auth 取得的 token 渲染用户模板；Process Supervisor Mode 负责把 Vault 机密作为环境变量注入子进程。

这六类能力并不意味着每一类都应该在新架构中同等使用。API proxy 已在 Agent 文档中标记为 deprecated，API 代理相关工作流应迁移到 Vault Proxy；Vault Agent 也不支持通过 API proxy 对 KV v1 或 KV v2 这类静态机密做静态缓存，官方同样建议将这类 API proxy 工作流交给 Vault Proxy。

因此，本节把 Vault Agent 作为“本机机密供给器”来讲解：一条主线是把 Vault 响应渲染为本地文件，另一条主线是用 Process Supervisor Mode 启动子进程并注入环境变量。Agent 的 API proxy 语法只作为历史边界说明，不作为现代课程的推荐实践；与代理相关的部署拓扑继续放在 7.3 Vault Proxy 中展开。

![Vault Agent 位于应用主机本地，一侧通过 Auto-auth 向 Vault 取得 token，另一侧把机密渲染成文件或注入子进程环境变量](/images/ch7-agent/agent-local-daemon.png)

---

## 2. 最小配置骨架：`vault`、`auto_auth`、`template`

一个典型的 Agent 配置至少要回答三个问题：Agent 连接哪一个 Vault Server，Agent 以什么身份完成自动认证，认证成功后把机密交付到哪里。第一个问题由 `vault` stanza 描述，第二个问题由 `auto_auth` stanza 描述，第三个问题通常由 `template` 或 `env_template` 与 `exec` 描述。

`vault` stanza 中的 `address` 指定 Agent 要连接的 Vault 地址，可以是 FQDN，也可以是 IP 加端口。配置文件中的地址可能被 `VAULT_ADDR` 环境变量覆盖，而环境变量又会被 CLI flag 覆盖；官方特别提醒，如果在 Agent 所在进程环境中把 `VAULT_ADDR` 指向 Agent 自己的 listener，Agent 可能尝试连接自身并不断递增端口，最终造成端口耗尽。

`auto_auth` stanza 描述 Agent 如何登录 Vault。官方 Agent 总览文档没有在本页展开每一种 auth method 的细节，但明确指出 Auto-auth 位于 `auto_auth` configuration stanza 中，并用于在多种环境中自动认证。认证取得的 token 随后可供模板渲染、缓存或 Process Supervisor Mode 使用。

`template_config` 与 `template` 是两层不同配置。`template_config` 在顶层只能定义一次，用来影响模板引擎整体行为，例如重试失败后是否退出、静态机密多久重新渲染一次、每个 Vault host 最多使用多少连接；`template` 则描述某一个具体模板从哪里读取内容、写到哪个 destination、缺少 key 时如何处理。

下面是一个最小化文件渲染示例。它把 KV v2 中的用户名和密码渲染成本地环境变量格式文件，适合让只会读取 `.env` 文件的应用使用。

::: v-pre
```hcl
vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "/etc/vault/role-id"
      secret_id_file_path = "/etc/vault/secret-id"
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

template {
  destination          = "/etc/app/app.env"
  error_on_missing_key = true
  perms                = "0600"
  contents             = <<-EOT
    APP_USER={{ with secret "secret/data/app" }}{{ .Data.data.username }}{{ end }}
    APP_PASSWORD={{ with secret "secret/data/app" }}{{ .Data.data.password }}{{ end }}
  EOT
}
```
:::

启动 Agent 的命令形式与 Vault Server 类似，使用 `vault agent -config=/etc/vault/agent-config.hcl`。`-config` 可以指向单个配置文件，也可以重复出现以组合多个配置文件，还可以指向一个目录，由 Agent 在启动时组合目录中的配置内容。

---

## 3. 模板语言与文件渲染

Vault Agent 模板使用 Consul Template markup。模板内容可以直接写在 `template` stanza 的 `contents` 字段中，也可以保存为独立 `.ctmpl` 文件，再由 `source` 字段引用；两者互斥，不能同时使用。

模板从 Vault 读取数据时，主要依靠 Consul Template 的 `secret` 函数与 `pkiCert` 函数。`secret` 可用于静态机密、动态凭据和证书等多类响应；`pkiCert` 专门面向 Vault PKI Secrets Engine 颁发的证书，并拥有不同于普通 `secret` 的证书刷新行为。

KV v2 的响应结构中，业务数据位于 `.Data.data` 下。因此，模板读取 `secret/data/app` 这类 KV v2 路径时，常见写法是 <code v-pre>{{ with secret "secret/data/app" }}{{ .Data.data.username }}{{ end }}</code>。如果模板引用的字段缺失，默认行为可能渲染为 `<no value>`；生产配置中应把 `template.error_on_missing_key` 设为 `true`，并配合 `template_config.exit_on_retry_failure = true`，使缺少关键字段时 Agent 明确失败，而不是继续产出不完整配置文件。

文件型模板还可以控制 destination、目录创建、权限、备份和渲染后执行命令。官方文档说明，如果 destination 的父目录不存在，Agent 默认会尝试创建；如果未指定 `perms`，Agent 会尽量沿用已有文件权限，若文件不存在则默认使用 `0644`；`backup = true` 时会为上一次渲染结果保留一个备份。

需要谨慎使用模板里的命令执行能力。旧的 `command` 和 `command_timeout` 已被官方标记为 deprecated，推荐使用 `exec` block；即便使用 `exec`，官方也提醒 Agent 不是进程监控器或 init system，命令需要在规定时间内返回成功退出码。

![Vault Agent 模板渲染流程：读取 template source 或 contents，用 Auto-auth token 调用 Vault，把结果写入 destination 文件](/images/ch7-agent/template-rendering-flow.png)

---

## 4. 机密刷新语义：不同机密并不同步刷新

Vault Agent 模板会自动续期或重新获取机密，但刷新时机取决于机密类型。理解这一点十分重要，因为“模板文件会刷新”并不等于“所有类型的机密都按同一频率刷新”。

对于可续期的 secret 或 token，Agent 会在 lease duration 已经过三分之二后续期。对于没有 lease、不可续期的静态机密，例如 KV v2，Agent 默认每 5 分钟重新获取一次；这个间隔可通过 `template_config.static_secret_render_interval` 调整。

对于不可续期但带 lease 的动态凭据，例如某些 database credentials，Agent 会在 TTL 达到约 90% 时重新获取，并加入抖动，以避免大量客户端同时请求 Vault。这个 90% 阈值可通过 `template_config.lease_renewal_threshold` 调整。

对于带 `rotation_period` 的静态角色，例如数据库静态角色，Agent 会通过检查 secret 的 TTL，在 Vault 中的值发生轮转时重新获取。对于 PKI 证书，自 Vault 1.11 起，证书可通过 `pkiCert` 或 `secret` 两种函数渲染；官方推荐使用 `pkiCert`，以避免 Agent 重启或重新认证时不必要地生成新证书。

`pkiCert` 与 `secret` 在证书场景中的行为差异尤其需要注意。使用 `pkiCert` 时，如果已有渲染证书尚未过期，Agent 重启或 auto-auth 重新认证通常不会重新签发；使用 `secret` 时，Agent 启动会获取新证书，auto-auth 重新认证也可能重新渲染新证书。

---

## 5. Process Supervisor Mode：把机密作为环境变量交给子进程

Process Supervisor Mode 允许 Agent 使用 `env_template` 把 Vault 机密渲染成环境变量，再用 `exec` block 启动一个子进程。这个模式适合无法读取配置文件、但能从环境变量读取配置的旧应用或命令行工具。

启动 Process Supervisor Mode 时，Agent 会等待每个 `env_template` 至少渲染成功一次，然后才启动 `exec.command` 指定的子进程。如果 `restart_on_secret_changes` 保持默认值 `always`，当静态机密按 `static_secret_render_interval` 检测到变化，或动态机密接近过期并刷新时，Agent 会重启子进程。

这个模式对进程生命周期有明确约束。Agent 会转发子进程的 stdin、stdout 和 stderr；如果子进程自行退出，Agent 会以相同退出码退出。配置层面要求至少有一个 `env_template` block，并且必须有且仅有一个顶层 `exec` block；它与常规文件型 `template` entries 不兼容。

`env_template` 与文件模板使用同一种模板语言，但只允许模板配置参数中的一个子集。常用字段包括环境变量名、`contents`、`source`、`error_on_missing_key`、`left_delimiter` 与 `right_delimiter`；其中环境变量名来自 `env_template` stanza 的标题。

下面的示例把 KV v2 中的用户名和密码注入到子进程环境中。与上一节的文件渲染不同，应用看不到本地 `.env` 文件，而是在启动时直接收到 `APP_USER` 和 `APP_PASSWORD`。

::: v-pre
```hcl
template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

env_template "APP_USER" {
  contents             = "{{ with secret \"secret/data/app\" }}{{ .Data.data.username }}{{ end }}"
  error_on_missing_key = true
}

env_template "APP_PASSWORD" {
  contents             = "{{ with secret \"secret/data/app\" }}{{ .Data.data.password }}{{ end }}"
  error_on_missing_key = true
}

exec {
  command                   = ["/usr/local/bin/my-app"]
  restart_on_secret_changes = "always"
  restart_stop_signal       = "SIGTERM"
}
```
:::

如果应用运行在 Kubernetes 集群中，不应把 Process Supervisor Mode 视作唯一选择。官方文档在该页明确提示，Kubernetes 工作负载应评估 Vault Secrets Operator 与 Vault Agent Sidecar Injector；本课程会在 7.4 及后续小节分别展开这些平台层集成方式。

![Process Supervisor Mode 先渲染 env_template，再启动 exec 子进程；机密变化时按配置重启子进程](/images/ch7-agent/process-supervisor-flow.png)

---

## 6. Caching 与 Persistent Cache 的真实边界

Vault Agent Caching 只缓存两类响应：通过 Agent 发起的 token creation 请求，以及使用 Agent 已管理 token 发起的 leased secret creation 请求。Agent 会管理这些缓存 token 和 lease 的续期，但这并不等同于“任意 Vault 读取都会被缓存”。

官方特别强调，Agent 不支持通过 API proxy 对 KV v1 或 KV v2 静态机密做静态缓存；如果目标是减少静态 KV API 请求转发到 Vault，应使用 Vault Proxy 的 static secret caching，而不是 Agent。

Agent 的 cache eviction 是尽力而为的。若 secret 达到 maximum TTL 或续期失败，相关 cache entry 会被驱逐；如果 token revoke 或 lease revoke 请求经由 Agent 且 Vault 成功处理，Agent 也会驱逐相关条目。但是，如果撤销操作由客户端绕过 Agent 直接向 Vault Server 发起，Agent 可能不知道这次撤销，从而暂时保留陈旧 cache entry；此时可使用 `/agent/v1/cache-clear` 手动清理。

默认情况下，Agent 的续期状态保存在内存中。Agent 进程停止后，续期操作立即终止；这并不表示 token 或 secret 被撤销，只表示 Agent 不再为仍然有效且未撤销的对象承担续期责任。

Persistent cache 可让新的 Agent 进程从前一个 Agent 进程留下的缓存文件恢复 token 和 lease。该缓存文件是 BoltDB 文件，内部包含由生成的加密密钥加密的 tuple，包括用于获取 secret 的 Vault token、token 或 secret 的 lease 以及 secret value。

Persistent cache 只恢复 leased secrets，不会持久化 KV v2 这类不可续期静态机密；它要求使用 auto-auth。如果恢复时 auto-auth token 已过期，缓存会失效，Agent 必须重新向 Vault 获取机密。

当前官方 persistent cache 只支持 Kubernetes 环境，类型为 `kubernetes`。在 Kubernetes persistent cache 中，ServiceAccount token 会参与缓存文件的加密与解密完整性校验；官方建议该缓存文件只用于 init Agent container 与 sidecar Agent container 之间交接 Vault token 和 lease，并通过 memory volume 共享。使用 Vault Agent Injector 时，设置 `vault.hashicorp.com/agent-cache-enable: true` 注解即可自动配置并使用它。

![Agent cache 只覆盖新建 token 和 leased secrets；KV 静态缓存和 API 代理工作流转向 Vault Proxy](/images/ch7-agent/cache-and-boundary.png)

---

## 7. 开发配置、平台运行与版本组合

`vault agent generate-config` 可以生成用于 Process Supervisor Mode 的开发配置文件。官方文档明确说明，这类开发配置会使用基于 CLI 当前 token 的 `token_file` 认证方法；这种方式便于本地测试，但不适合生产环境，生产中应使用更稳健的 auto-auth 方法。

生成配置时可指定 `-type="env-template"`、`-exec`、`-namespace` 与一个或多个 `-path`。生成结果会为显式路径中的 key 生成 `env_template`，对以 `/*` 结尾的路径进行递归时，也会为遇到的 key 生成环境变量模板；变量名形式为 `<final_path_segment>_<key_name>`。

Windows 平台可以把 Vault Agent 注册为 Windows Service。官方示例提供了 `sc.exe` 与 PowerShell `New-Service` 两种方式，并提醒必须以管理员能力运行命令；在配置文件中书写 Windows 路径时，应使用 `C:/foo/bar/file.txt` 这种正斜杠形式，而不是反斜杠形式。

使用 `sc.exe` 注册服务时，必须写成 `sc.exe` 而不是 `sc`，并确保 executable path 被正确加引号，尤其是路径中含有空格时，否则可能带来 privilege escalation 风险。若路径包含空格，`New-Service` 对引号转义通常更容易处理。

Vault Agent 与 Vault Server 不要求运行完全相同的版本。官方说明，混用不同版本通常是安全的，但可能无法使用最新功能；Agent 在检测到版本不一致时会向日志写入提示，这个提示只用于辅助排错。

当 Agent 版本较旧而 Server 较新时，现有 auth method 通常继续工作，但新 auth method 不可用；模板通过稳定的 Vault API 读取和续期机密，通常不需要因为新的 secret engine 类型出现而升级 Agent。当 Agent 版本较新而 Server 较旧时，如果 Agent 依赖旧 Server 不具备的新能力，就可能无法工作；模板本身通常不预期破坏兼容性，但模板内容若显式调用旧 Server 不支持的新参数或路径，仍会失败。

`pki_external_ca` 是 Agent 文档中较新的证书自动化能力，但该页面明确标注 Enterprise-only，要求 Vault Enterprise v2.0.0 或更高版本，并用于让 Agent 作为 ACME client 自动化公有证书机构的证书生命周期。本书当前课程范围以开源版可复现实验为主，因此本节只把它作为边界知识说明，不纳入后面的动手实验。

---

## 8. 互动实验

本节配套实验让学员在同一台 Vault dev server 上完成两条 Agent 主线：先让 Agent 使用 AppRole 自动认证并把 KV v2 机密渲染成本地文件，再让 Agent 使用 Process Supervisor Mode 把同一份机密注入子进程环境变量，并在机密更新后观察模板文件刷新与子进程重启。

实验会刻意把 `static_secret_render_interval` 调短到 `10s`，以便在交互式环境中观察 KV v2 静态机密重新渲染。真实生产环境中，这个间隔应结合 Vault 负载、配置变更频率和应用容忍度谨慎设置。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-agent" title="实验：用 Vault Agent 渲染文件并注入环境变量" />