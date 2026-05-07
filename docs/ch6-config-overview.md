---
order: 61
title: 6.1 配置文件架构纵览与现代 HCL 语法规范
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.1 配置文件架构纵览与现代 HCL 语法规范

> **核心结论**：除开发模式（dev mode）外，Vault 服务器都要从一个配置文件启动，文件可使用 HCL 或 JSON 两种格式书写；通过 `vault server -config=...` 指定路径后，Vault 才知道把数据写到哪个存储后端、监听哪些地址、是否启用自动解封以及如何输出遥测与日志。

本节面向已经能够在 dev 模式中操作 Vault 的学习者，目标不是穷举每一个参数，而是先把配置文件的整体骨架、顶层块的职责、命名块（labelled block）的语法形态以及几个最容易踩坑的全局开关讲清楚，作为后续章节深入存储后端、监听器、自动解封、Autopilot、遥测的统一前置基础。

如果你尚未系统学习过 HashiCorp 自家的配置语言 HCL，建议先阅读 [HCL 语法速成教程](https://lonegunmanb.github.io/terraform-tutorial/syntax.html) 中关于 attribute、block、label、表达式与字符串的部分，再回到本节继续阅读。本节不重复教 HCL 的基础语法，只解释 Vault 配置文件特有的结构约定与运行时行为。

---

## 1. 配置文件在 Vault 启动流程中的位置

Vault 服务器启动时，必须先读取一个配置文件才能进入“等待初始化 / 等待解封 / 正常运行”的状态机。配置文件的格式是 HCL 或 JSON，二者完全等价；文件写好后，使用 `vault server -config=/etc/vault.d/vault.hcl` 这类命令启动 Vault，`-config` 标志用于告诉 Vault 配置文件所在位置。

> 与 dev 模式的关系：dev 模式由 `vault server -dev` 启动，会自动初始化、自动解封并在内存中保存数据，因此不需要配置文件；但 dev 模式不适合任何带状态的实验之外的用途。本章假设你正在为非 dev 模式的服务器准备配置文件。

![Vault 启动时读取配置文件后进入解封等待状态的整体流程示意图](/images/ch6-config-overview/vault-config-startup-flow.png)

---

## 2. 顶层结构：参数（attribute）与命名块（labelled block）

Vault 配置文件由两种语法元素组合：直接写在文件最外层的标量参数，例如 `ui = true`、`cluster_name = "vault-prod"`；以及形如 `storage "raft" { ... }`、`listener "tcp" { ... }`、`seal "awskms" { ... }`、`telemetry { ... }` 的块结构。块名后面紧跟的字符串称为 label，用于声明这一块要使用哪一种实现（例如哪一种 storage backend、哪一种 listener 类型、哪一种 seal 类型）。

`telemetry` 这种没有 label 的块，意味着 Vault 全局只有一份遥测配置；而 `listener "tcp"`、`storage "raft"`、`seal "awskms"` 这种带 label 的块，label 用来在同一类配置中区分不同实现。HCL 的 attribute、block 与 label 概念本身不属于 Vault 特有内容，建议在 [HCL 语法速成教程](https://lonegunmanb.github.io/terraform-tutorial/syntax.html) 中补齐基础。

下面是官方文档中给出的最小完整示例，可以作为本章后续深入各子章节时反复回看的“地图”：

```hcl
ui            = true
cluster_addr  = "https://127.0.0.1:8201"
api_addr      = "https://127.0.0.1:8200"
disable_mlock = true

storage "raft" {
  path    = "/path/to/raft/data"
  node_id = "raft_node_id"
}

listener "tcp" {
  address       = "127.0.0.1:8200"
  tls_cert_file = "/path/to/full-chain.pem"
  tls_key_file  = "/path/to/private-key.pem"
}

telemetry {
  statsite_address = "127.0.0.1:8125"
  disable_hostname = true
}
```

> 多节点集群部署时，需要把示例中的回环地址 `127.0.0.1` 替换为该 Vault 节点在网络中的可被路由 IP；这一点在官方文档对该示例的提示框中单独说明。

---

## 3. 必填顶层参数：storage 与 listener

`storage` 是配置文件中**必填**的块，它声明 Vault 把加密后的数据持久化到哪个后端。如果选用的存储后端原生支持高可用协调，那么相关高可用参数可以直接写在 `storage` 块内；否则需要再额外定义一个 `ha_storage` 块，由它承担高可用协调职责。

`listener` 同样是**必填**项，用于声明 Vault 在哪些地址、端口上接收 API 请求；具体可配置字段在第 6.2 节展开。

`seal` 块用于声明自动解封（auto-unseal）所使用的 seal 类型，并可作为额外的数据保护层为 seal wrap 机制提供配置入口；它本身不是必填项。

---

## 4. 高可用相关参数：api_addr、cluster_addr、disable_clustering

当存储后端支持高可用时，Vault 集群中的节点之间需要互相找到对方，这通过两个“通告地址”实现：

- `api_addr`：本节点向集群中其他节点通告的、可供客户端被重定向到的完整 API URL；该值同时被插件后端使用，可由环境变量 `VAULT_API_ADDR` 提供，通常应当与 `listener` 块的实际对外地址保持一致。
- `cluster_addr`：本节点向集群中其他节点通告的、用于请求转发的完整地址；可由环境变量 `VAULT_CLUSTER_ADDR` 提供。该值在格式上与 `api_addr` 一致，但 Vault 会忽略其中的 scheme，因为集群成员之间始终强制使用基于私有密钥与证书的 TLS。
- `disable_clustering`：是否关闭请求转发等集群特性；只有当本节点恰好是 active 节点时，把它设为 `true` 才会真正生效；如果存储类型是 `raft`，则**不允许**把这个参数设为 `true`。

`api_addr` 与 `cluster_addr` 都支持 [go-sockaddr 模板](https://pkg.go.dev/github.com/hashicorp/go-sockaddr/template) 写法，便于在运行时根据节点自身的网卡情况动态求值；这在使用容器编排或自动伸缩时非常关键。

![api_addr 与 cluster_addr 的差异：客户端流量与节点间转发使用不同通告地址](/images/ch6-config-overview/api-addr-vs-cluster-addr.png)

---

## 5. 全局行为开关：mlock、缓存、UI、PID 文件

下列顶层参数会显著改变 Vault 进程的运行时行为，建议在第一次起服务前就明确选定：

- `disable_mlock`（**必填，bool**）：是否阻止 Vault 调用 `mlock` 系统调用；`mlock` 用于阻止内存换页到磁盘。文档明确要求：当使用 integrated storage（即 raft 存储）时，**必须**显式给出该参数的取值，并且**强烈建议**把它设为 `true`，因为 `mlock` 与 BoltDB 这类内存映射文件配合得不好，会把整个数据集都常驻内存。该参数也可以通过环境变量 `VAULT_DISABLE_MLOCK` 提供。
- `cache_size`（默认 `"131072"`）：物理存储子系统使用的读缓存条目数；总占用还取决于条目大小。
- `disable_cache`（默认 `false`）：禁用 Vault 内部所有缓存，包括上面的物理存储读缓存；文档警告“会显著影响性能”，因此通常仅在排错时短暂开启。
- `ui`（默认 `false`）：是否启用内置 Web UI；启用后所有 listener 的 `/ui` 路径都会暴露 UI，浏览器访问标准 API 地址会被自动重定向过去；可通过环境变量 `VAULT_UI` 提供。
- `pid_file`（默认 `""`）：把 Vault 进程的 PID 写入指定文件，便于运维脚本发送信号或检查进程。
- `cluster_name`（默认自动生成）：人类可读的集群名，会以标签形式出现在部分遥测指标中；该名称在已存在的集群上也可以安全地修改。

> 关于 `disable_mlock` 的安全权衡：文档同时说明，在不使用 integrated storage 的部署中**不建议**禁用 `mlock`；要使用 `mlock`，Vault 可执行文件以及 plugin 目录中的每个插件可执行文件都需要具备调用该系统调用的能力。在 Linux 上一种典型做法是 `sudo setcap cap_ipc_lock=+ep $(readlink -f $(which vault))`，或在使用现代 systemd 时配置 `LimitMEMLOCK=infinity`。

---

## 6. 租约与请求时长的全局默认

Vault 的所有 token 与机密都附带租约（lease）；下面两个顶层参数提供租约时长的全局默认与上限：

- `default_lease_ttl`（默认 `"768h"`）：token 与机密的默认租约时长，使用 `30s`、`1h` 这类带后缀的字符串书写；该值不能大于 `max_lease_ttl`。
- `max_lease_ttl`（默认 `"768h"`）：token 与机密所允许的最大租约时长；单个挂载点可以通过 `vault auth tune -max-lease-ttl=...` 或 `vault secrets tune -max-lease-ttl=...` 覆盖该全局上限。
- `default_max_request_duration`（默认 `"90s"`）：单次请求允许执行的最长时间，超时后 Vault 会取消该请求；可在每个 listener 中通过 `max_request_duration` 覆盖。

---

## 7. 日志与可观测性的入口

日志相关的顶层参数与第 5.6 节中介绍 Vault Proxy 时所见的命令行选项基本一一对应：

- `log_level`（默认 `"info"`）：详尽程度从高到低依次为 `trace`、`debug`、`info`、`warn`、`error`；可通过环境变量 `VAULT_LOG_LEVEL` 覆盖。文档明确说明：在 Vault 进程上发送 `SIGHUP` 信号（例如 `sudo kill -s HUP <vault pid>`）后，如果配置中给出的日志级别合法，Vault 会**就地更新**日志级别，并且会同时覆盖命令行参数与环境变量给出的值；但不是所有子模块的日志级别都能这样动态变更，特别是 secrets/auth 插件目前不会跟随更新。
- `log_format`、`log_file`、`log_rotate_duration`、`log_rotate_bytes`、`log_rotate_max_files`：与 `vault server` 的同名命令行标志一一等价。
- `telemetry`（块）：声明遥测上报系统；详细字段在 6.8 节展开。

> 把 `SIGHUP` 重新理解一遍：除了刷新日志级别，Vault 在收到 SIGHUP 时还会尝试重新加载 listener 的 TLS 配置，这是在不中断服务的情况下轮换证书的标准方式；这一点在第 6.2 节会详述。

---

## 8. 插件目录与文件权限相关

`plugin_directory`（默认 `""`）声明 Vault 允许从哪个目录加载插件；Vault 必须有读权限才能成功加载，并且这个值不能是符号链接。`plugin_tmpdir` 是 Vault 用于支持容器化插件 Unix socket 通信的临时目录，通常无须设置，除非使用容器化插件且 Vault 与其它进程不共享临时目录（例如使用了 systemd 的 `PrivateTmp`），可通过环境变量 `VAULT_PLUGIN_TMPDIR` 提供。`plugin_file_uid` 与 `plugin_file_permissions` 仅在通过环境变量 `VAULT_ENABLE_FILE_PERMISSIONS_CHECK` 启用文件权限检查时才需要设置。

---

## 9. 其它常见但容易被忽视的开关

- `raw_storage_endpoint`（默认 `false`）：启用 `sys/raw` 端点，允许在安全屏障两侧对原始数据做加密 / 解密；这是一个**高度特权**的端点，通常仅在数据迁移或紧急排错时短暂开启。
- `introspection_endpoint`（默认 `false`）：启用 `sys/internal/inspect` 端点，仅允许 root token 或具有 sudo 权限的用户检查 Vault 内部部分子系统。
- `enable_response_header_hostname`（默认 `false`）：在所有 HTTP 响应中加入 `X-Vault-Hostname` 头，给出服务该请求的节点主机名；此为尽力而为，无法保证一定出现。
- `enable_response_header_raft_node_id`（默认 `false`）：在所有 HTTP 响应中加入 `X-Vault-Raft-Node-ID` 头，仅当 Vault 使用 integrated storage 时才会真正出现该头。
- `detect_deadlocks`：以逗号分隔的字符串声明需要监控潜在死锁的内部互斥锁，目前支持 `statelock`、`quotas`、`expiration`；启用后可能因为追踪每次加锁尝试而带来负面性能影响。
- `experiments` / `enable_post_unseal_trace` / `post_unseal_trace_directory` / `allow_audit_log_prefixing` / `enable_unauthenticated_access`：均为面向特定排错或迁移场景的高级开关，初次配置时通常无需设置。

---

## 10. 教学实验配置示例

下面给出本节互动实验中将使用的最小可启动配置。它选择 `raft` 作为存储后端，监听在 `127.0.0.1:8200`，关闭 TLS 仅用于教学；正式环境必须启用 TLS。

```hcl
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

default_lease_ttl = "168h"
max_lease_ttl     = "720h"
```

字段选取依据：`storage` / `listener` 必填，`disable_mlock` 在使用 integrated storage 时必须显式给出，`api_addr` 与 `cluster_addr` 用于让节点向集群通告自己的位置，`default_lease_ttl` / `max_lease_ttl` 演示如何覆盖默认 768 小时。

---

## 11. 互动实验

本节配套了一个 Killercoda 实验，学员将基于上述配置文件启动一个真实的 Vault 服务器（非 dev 模式），并完成下列练习：

- **Step 1**：阅读预置的 `vault.hcl`，识别其中的顶层参数与命名块，对照本文 1-9 节定位每一项的职责。
- **Step 2**：使用 `vault server -config=...` 启动服务，初始化并解封，体验“没有配置文件就无法启动”这一前提。
- **Step 3**：通过修改 `log_level` 并发送 `SIGHUP` 验证日志级别可被就地刷新；同时观察 SIGHUP 不会重启进程。
- **Step 4**：故意把 `disable_mlock` 删除，复现 raft 存储下启动失败的报错信息；理解为什么文档把这一项标为必填。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-config-overview" title="实验：Vault 配置文件骨架与全局开关" />
