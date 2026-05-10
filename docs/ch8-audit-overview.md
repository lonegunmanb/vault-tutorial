---
order: 81
title: 8.1 审计日志综述
group: 第 8 章：安全合规审计与系统观测
group_order: 80
---

# 8.1 审计日志综述

> **核心结论**：Vault 的「审计日志（audit log）」与日常运维看到的「服务器日志
> （server log）」是两套完全不同的日志体系。审计日志会以结构化 JSON 的形式，
> 一条不漏地记录 Vault API 收到的每一个请求和发回的每一个响应，用于事后追溯
> 「谁、在什么时间、从哪里、对哪条机密、做了什么操作」。审计能力以「审计设备
> （audit device）」的形式按需挂载，开源版内置三种类型：`file`、`syslog`、
> `socket`。本节先建立统一心智模型，后续 8.2 一节集中展开三种设备的具体
> 配置方法，8.3 给出最佳实践清单。

参考：
- [Audit logging — Vault Docs](https://developer.hashicorp.com/vault/docs/audit)
- [Audit log entry schema — Vault Docs](https://developer.hashicorp.com/vault/docs/audit/schema)

---

## 1. 审计日志和服务器日志不是同一回事

初学者很容易把 Vault 启动后在终端打印出来的那一大段日志，误认为就是「审计
日志」。实际上，那种由 Vault 服务进程自身产生、用来描述进程错误、配置告警
等运行状态的内容，在官方文档中被称作「服务器日志（server log，又叫
operational log）」，而本章讨论的「审计日志（audit log）」则是另一套独立的
日志，专门记录 Vault API 收到的每一个请求与发回的每一个响应的详细内容。

换言之，服务器日志回答的是「Vault 进程本身现在健康吗」这样的运维问题，而
审计日志回答的是「过去某一个时刻，是哪个客户端、用什么令牌、对哪条 API
路径做了什么操作、得到了什么样的响应」这样的合规与追责问题。后续在第 8 章
中讨论的所有内容都属于审计日志的范畴。

![Vault 同时输出两类日志：服务器日志记录进程自身运行状态，审计日志记录每一个 API 请求与响应的详细内容](/images/ch8-audit-overview/two-log-streams.png)

---

## 2. 审计设备：审计日志的「出口」抽象

Vault 并不规定审计日志「必须」写到某一个固定位置，而是把「日志要往哪里送」
这件事抽象成了「审计设备（audit device）」。一台 Vault 集群可以同时挂载
多台审计设备，每挂载一台，Vault 就会把同一份审计记录复制一份送给它。开源版
内置了三种类型的审计设备：写本地文件的 `file`、写远端 syslog 服务器的
`syslog`、以及写到任意 TCP/UDP/Unix Socket 的 `socket`。

新初始化的 Vault 集群默认 **没有任何审计设备处于启用状态**，必须通过
`vault audit enable` CLI、`/sys/audit` API 或 Terraform Vault provider 等
方式显式启用。启用时除了类型本身的专属选项（例如 `file` 设备的 `file_path`），
还可以指定一组对所有设备都通用的公共选项（例如是否对令牌 accessor 做
HMAC、是否对 LIST 响应做省略等）。

审计设备的配置在集群所有节点之间会自动复制，确保任何一个节点接到请求时
都能正确地写日志。换句话说，一旦在某个节点上挂载了一台审计设备，集群其它
节点也会同步获得这条配置；因此在启用之前，必须先确认 **所有 Vault 节点
都能成功访问到该设备的目标位置**（例如本地文件路径要存在并可写、syslog
端点可达、socket 服务监听正常），否则会因为「有节点写不出去」而引发后续
小节将要介绍的「请求被拒绝」问题。

禁用审计设备是一个「立即停笔」的动作：执行禁用之后，Vault 立刻不再向该
设备写入新的审计记录，但 **已经写入的历史日志不会被清理或修改**。需要特别
注意的是，禁用以后就再也无法对那一段历史日志中被 HMAC 处理过的字段做
反查（也就是后文会讲到的 `sys/audit-hash` 操作），因为每次启用审计设备
时 Vault 会重新生成一把哈希密钥，即便之后在同一路径上再次启用同名设备，
也会换成一把新的密钥。

![同一份审计记录会被同时投递到所有已启用的审计设备，记录顺序与目标位置相互独立](/images/ch8-audit-overview/audit-device-fanout.png)

---

## 3. 「至少写出去一份」：审计日志的可用性约定

Vault 在日志可用性问题上采取了一种非常严格的策略：每收到一个 API 请求，
Vault 都会尝试把对应的审计记录发给 **所有已启用的审计设备**，并要求至少
有一台设备成功把这条记录持久化下来；只要还有任何一台启用中的审计设备
能够正常写入，Vault 就照常处理业务请求。

反过来，一旦所有已启用的审计设备 **同时** 都写不出去（例如挂载的目标
syslog 服务器宕机、本地磁盘写满、socket 对端不响应等），Vault 就会拒绝
为该请求继续提供服务。这条约束意味着，「审计日志是否可写」会直接决定
「Vault 业务 API 是否可用」——审计设备一旦全部阻塞，Vault 在外部看来
就等同于不可用。

为了避免出现「单一审计设备挂掉就把整个 Vault 拖死」的尴尬局面，HashiCorp
明确建议在生产环境中至少启用两台审计设备，并在事后分析时把所有设备的
日志合并去重，以确保对每一个 API 请求与响应都拥有完整的记录。

![所有已启用审计设备同时阻塞时，Vault 会主动拒绝业务请求；至少两台设备并行可显著降低这种风险](/images/ch8-audit-overview/availability-rule.png)

---

## 4. 审计日志的内容形态：一行一个 JSON 对象

每一条审计日志都是一个独立的 JSON 对象，对象与对象之间用换行符分隔，因此
日志文件本身可以直接被以「逐行 JSON（NDJSON）」格式读取的工具消费。每条
记录都包含一些跨所有 API 端点都通用的顶层字段，以及与具体端点相关的
请求和响应字段。

每一次 API 调用在审计日志里会同时产生 **两条** 记录：一条 `type` 字段为
`request` 的请求记录，一条 `type` 字段为 `response` 的响应记录。这两条
记录可以通过 `request` 对象内部的 `id` 字段（即 `.request.id`）一一配对，
便于事后把同一次调用的入参与出参拼接还原。

每条记录顶层都至少包含 `auth`、`request`、`time`、`type` 这几个字段，
分别描述「发起请求的认证主体」、「请求详情」、「请求/响应发生的 ISO 8601
时间戳」以及「这条记录是 request 还是 response」；如果请求出错，会附加
一个 `error` 字段；响应记录还会多出 `response` 子对象描述响应详情；如果
请求是被一台 performance standby 节点转发到主节点处理的，则会附加
`forwarded_from` 字段。

`auth` 子对象描述的是「这次操作背后到底是哪个身份发起的」，包含令牌
accessor、令牌 display name、关联的 entity ID、生效的 ACL 策略列表、令牌
类型（service / batch / periodic）、令牌签发时间与 TTL 等关键字段，因此
是事后定位「是谁干的」最重要的入口。

`request` 子对象描述的是 **这次 API 请求本身**，包含 Vault 给这次请求
随机分配的 `id`、操作类型（`create` / `read` / `update` / `delete` /
`list`）、命名空间、被请求的 API 路径、原始 HTTP 路径、挂载点 accessor
与类型、客户端 IP 与端口、被允许记录的请求 header、wrap_ttl 等。

`response` 子对象描述的是 **Vault 这次返回了什么**，可能包含一个嵌套
的 `auth` 对象（适用于登录类 API，描述这次新签发的令牌信息）、响应
header、响应数据、租约信息（`secret.lease_id`）、响应包装信息
（`wrap_info`）以及可能的 warnings 列表。

![一次 API 调用在审计日志里产生两条 JSON 记录，可通过 .request.id 一一配对](/images/ch8-audit-overview/request-response-pair.png)

为了让上述抽象描述更加具象，下面直接引用官方文档 *Audit log entry schema*
中给出的一对真实样例（场景为：用户 `alice` 通过 userpass 登录后，对
`auth/token/lookup-self` 端点发起一次 `read` 操作以查看自身令牌信息）。
先看 **请求记录（`type: request`）**：

```json
{
  "auth": {
    "accessor": "hmac-sha256:3348fe9b24b078f97d747363dda2d55bb0445e90b512e9f68f48d289fed798b3",
    "client_token": "hmac-sha256:c39c69748f0894cb4cd0333c779e72343ba45af287649d0fbcc37e9b079abe5d",
    "display_name": "userpass-alice",
    "entity_id": "62ff123b-7609-1ed9-5707-ea621da72de7",
    "metadata": { "username": "alice" },
    "policies": ["default"],
    "policy_results": {
      "allowed": true,
      "granting_policies": [
        { "type": "" },
        { "name": "default", "namespace_id": "root", "type": "acl" }
      ]
    },
    "token_policies": ["default"],
    "token_issue_time": "2025-06-04T16:01:31-04:00",
    "token_ttl": 2764800,
    "token_type": "service"
  },
  "request": {
    "client_id": "62ff123b-7609-1ed9-5707-ea621da72de7",
    "client_token": "hmac-sha256:3431e8c2ce0e5f5e179a857fcf9d948afd83363de9f64a5e956851262e1285e0",
    "client_token_accessor": "hmac-sha256:3348fe9b24b078f97d747363dda2d55bb0445e90b512e9f68f48d289fed798b3",
    "headers": { "user-agent": ["Go-http-client/1.1"] },
    "id": "79cc9b26-488f-eabf-2a97-303ed3bef0d6",
    "mount_class": "auth",
    "mount_point": "auth/token/",
    "mount_running_version": "v1.19.1+builtin.vault",
    "mount_type": "token",
    "namespace": { "id": "root" },
    "operation": "read",
    "path": "auth/token/lookup-self",
    "remote_address": "127.0.0.1",
    "remote_port": 64199
  },
  "time": "2025-06-04T20:02:46.117181Z",
  "type": "request"
}
```

可以看到，`auth.display_name` 直接以明文 `userpass-alice` 出现，而
`auth.client_token`、`auth.accessor`、`request.client_token` 等敏感字段
均已被替换为 `hmac-sha256:...` 形式的哈希串——这正是第 5 节即将展开的
HMAC 默认保护策略在样例中的体现。`request.id` 字段的值
`79cc9b26-488f-eabf-2a97-303ed3bef0d6` 就是稍后用来与响应记录配对的
关键凭据。

紧接着是同一次调用的 **响应记录（`type: response`）**：

```json
{
  "auth": {
    "accessor": "hmac-sha256:3348fe9b24b078f97d747363dda2d55bb0445e90b512e9f68f48d289fed798b3",
    "client_token": "hmac-sha256:c39c69748f0894cb4cd0333c779e72343ba45af287649d0fbcc37e9b079abe5d",
    "display_name": "userpass-alice",
    "entity_id": "62ff123b-7609-1ed9-5707-ea621da72de7",
    "metadata": { "username": "alice" },
    "policies": ["default"],
    "policy_results": {
      "allowed": true,
      "granting_policies": [
        { "type": "" },
        { "name": "default", "namespace_id": "root", "type": "acl" }
      ]
    },
    "token_policies": ["default"],
    "token_issue_time": "2025-06-04T16:01:31-04:00",
    "token_ttl": 2764800,
    "token_type": "service"
  },
  "request": {
    "client_id": "62ff123b-7609-1ed9-5707-ea621da72de7",
    "client_token": "hmac-sha256:3431e8c2ce0e5f5e179a857fcf9d948afd83363de9f64a5e956851262e1285e0",
    "client_token_accessor": "hmac-sha256:3348fe9b24b078f97d747363dda2d55bb0445e90b512e9f68f48d289fed798b3",
    "headers": { "user-agent": ["Go-http-client/1.1"] },
    "id": "79cc9b26-488f-eabf-2a97-303ed3bef0d6",
    "mount_accessor": "auth_token_d43d387d",
    "mount_class": "auth",
    "mount_point": "auth/token/",
    "mount_running_version": "v1.19.1+builtin.vault",
    "mount_type": "token",
    "namespace": { "id": "root" },
    "operation": "read",
    "path": "auth/token/lookup-self",
    "remote_address": "127.0.0.1",
    "remote_port": 64199
  },
  "response": {
    "data": {
      "accessor": "hmac-sha256:3348fe9b24b078f97d747363dda2d55bb0445e90b512e9f68f48d289fed798b3",
      "creation_time": 1749067291,
      "creation_ttl": 2764800,
      "display_name": "hmac-sha256:e9fb3affb6ae22b7f747e1a60bdda5b57809c9e64ae6f39ebac24e371e6b9d89",
      "entity_id": "hmac-sha256:d2458e3011b3567a0070f22bcdd5e513aeb3473457922e1866f01463ccce2b11",
      "expire_time": "2025-07-06T16:01:31.771304-04:00",
      "explicit_max_ttl": 0,
      "id": "hmac-sha256:c39c69748f0894cb4cd0333c779e72343ba45af287649d0fbcc37e9b079abe5d",
      "issue_time": "2025-06-04T16:01:31.771306-04:00",
      "meta": {
        "username": "hmac-sha256:b93081f3689ff25929e88d5c323631ccf7d6145cd9f33c0c5129a7a340248b9a"
      },
      "num_uses": 0,
      "orphan": true,
      "path": "hmac-sha256:82f79af6be9e1d33d6821a8cfcfcba3196e5ec68512c1f5ed4c919acd8443dd6",
      "policies": [
        "hmac-sha256:1b1a37ccd3a6a78da781140396f04eb50e3460504492d2da75b446d775d3325b"
      ],
      "renewable": true,
      "ttl": 2764725,
      "type": "hmac-sha256:b835fe7ff7616f2023c77f6dbddc7afd83ef5c6644aba61c574c378dda710809"
    },
    "mount_accessor": "auth_token_d43d387d",
    "mount_class": "auth",
    "mount_point": "auth/token/",
    "mount_running_plugin_version": "v1.19.1+builtin.vault",
    "mount_type": "token"
  },
  "time": "2025-06-04T20:02:46.117567Z",
  "type": "response"
}
```

这条响应记录有几处对比要点值得初学者反复揣摩：第一，它的 `request.id`
与上一条请求记录完全相同，证明两者属于同一次 API 调用；第二，
`time` 字段比请求记录晚了大约 0.4 毫秒，正好对应 Vault 处理这次请求所
花费的时间；第三，多出来的 `response.data` 子对象里出现了大量
`hmac-sha256:...` 字符串，说明 **响应体内部本来由 Vault 返回给客户端的
明文敏感字段（例如令牌 ID、显示名、策略名、路径），在落入审计日志之前
也被统一做了哈希处理**，与「写出去的不是机密本体而是机密的指纹」这一
原则保持一致。

除此之外，官方文档还给出了带 `error` 字段与 `forwarded_from` 字段的
「失败 / 转发」情况的简化骨架，便于理解这两个可选顶层字段的出现时机：

```json
// 请求出错（type: request）
{
  "auth":   "<authentication object>",
  "error":  "error converting input {\"name\":\"John\"} for field \"data\": '' expected a map, got 'string'",
  "forwarded_from": "vault-1.prod.corp.com:443",
  "request": "<request object>",
  "time":   "2025-06-05T16:10:22.292517Z",
  "type":   "request"
}
```

```json
// 响应出错（type: response）
{
  "auth":   "<original authentication object>",
  "error":  "1 error occurred:\n\t* invalid request\n\n",
  "forwarded_from": "vault-1.prod.corp.com:443",
  "request":  "<original request object>",
  "response": "<response object>",
  "time":    "2025-06-05T16:10:22.292639Z",
  "type":    "response"
}
```

这两段骨架说明：`error` 字段只在出错时出现，并会同时出现在 request 与
response 两条记录里；而 `forwarded_from` 字段则只在请求被 performance
standby 节点转发到主节点处理时才会附加上集群中实际转发节点的 host
与端口。

---

## 5. 敏感信息的默认保护：HMAC 哈希

审计日志记录的内容包含令牌、机密 payload 等高度敏感的字段，如果直接以
明文写入日志文件，就等同于把机密「分散」到了日志收集链路的每一个环节，
违背了 Vault 集中保护机密的初衷。为此，Vault 在写入审计日志之前，默认会
对绝大多数字符串型字段做一次 **带密钥的 HMAC-SHA256** 哈希处理，只把
哈希结果写入日志，从而既保留了「能看出两条记录引用了同一个值」的能力，
又避免直接泄露原始内容。

需要特别提醒初学者的一点是：Vault **只会哈希字符串类型的值**，整数、布尔
等非字符串类型不会被哈希处理。因此官方建议，如果业务中有原本是数字但属于
敏感数据的字段（例如年龄、身份编号），写入 Vault 时应当主动用引号包裹成
JSON 字符串，确保它们也能被正确哈希。

如果在事后排查中已经知道某个值的原文，希望确认它是否对应日志里的某条
哈希记录，可以调用 `/sys/audit-hash` API，让 Vault 用某台审计设备对应
的密钥对该原文重新计算一次 HMAC，再与日志中的哈希值比对；除此之外，也
可以在启用单个认证后端或机密引擎时，通过 `tune` 操作选择性地把指定字段
从哈希列表中豁免出去（这一能力同样是开源版可用）。

---

## 6. 大响应体的省略：`elide_list_responses`

某些 LIST 类型的 API 响应可能非常庞大——例如列出所有活跃租约时，单条
响应数据就可能达到数十兆字节。如果原样写入审计日志，下游审计设备未必
能处理这么大的单条记录，反而会被「噎住」。

为了缓解这一问题，可以在启用审计设备时打开 `elide_list_responses`
选项：开启后，Vault 在写日志时不会把 LIST 响应里的 `keys` 与 `key_info`
字段原样落盘，而是会把它们替换成「实际包含了多少条」的整数计数，从而
显著降低单条审计记录的体积，但仍保留「这次 LIST 大约返回了多少结果」
这一级别的可观测信息。

---

## 7. 请求 Header 的记录范围

并不是 HTTP 请求里的所有 Header 都会被原样写进审计日志。Vault 默认只会
记录三个 Header：`User-Agent`、`Correlation-Id` 和 `X-Correlation-Id`。
如果业务方希望让审计日志额外包含某些自定义 Header（例如内部的请求来源
追踪 Header），可以通过 `/sys/config/auditing` 端点显式追加。

需要注意的是，被记录的请求 Header **默认不会被哈希**。如果某个 Header
本身就承载了敏感信息（例如内部签名、租户密钥等），需要在配置中显式为它
打开 HMAC 选项，让 Vault 在落盘前对其做哈希处理。

---

## 8. 不会被审计的 API 端点

并非所有 API 调用都会进入审计日志。Vault 有一份明确的「豁免清单」，落在
这份清单里的端点不会触发审计记录，主要分为两类：一类是与「集群初始化、
封印/解封、领导者发现、健康检查、rekey、Raft 引导/加入」等启动期或灾难
恢复期相关的端点，例如 `sys/init`、`sys/seal`、`sys/unseal`、`sys/health`、
`sys/leader`、`sys/rekey/*`、`sys/storage/raft/bootstrap` 等；另一类是
当对应监听器允许未认证访问时的诊断与监控端点，例如 `sys/metrics`、
`sys/pprof/*`、`sys/in-flight-req`。

理解这份清单的存在很重要，因为它意味着：仅靠审计日志 **无法** 追溯例如
「某节点何时被封印 / 解封」「某个时间点谁触发了 rekey」这类操作，初学者
需要把这部分痕迹的获取转交给后续将要讲到的 server log（操作日志）去
完成，而不应该期望审计日志覆盖一切。

---

## 9. 本节小结与后续章节衔接

本节建立了进入第 8 章后续小节所必需的统一心智模型，可以归纳为以下几条
要点供初学者反复回顾：

第一，审计日志与服务器日志是两套并行的日志体系，分别承担「合规追溯」与
「运维诊断」职责，不要混为一谈。

第二，审计能力以「审计设备」的形式按需挂载，开源版内置 `file`、`syslog`、
`socket` 三种类型，集群所有节点共享同一份配置。

第三，Vault 要求每条审计记录至少要被一台启用中的审计设备成功保存；
所有设备同时阻塞时 Vault 业务不可用，因此生产环境应至少启用两台审计
设备并合并分析。

第四，审计日志是一行一个 JSON 对象，每次调用产生 request 与 response
两条记录，可通过 `.request.id` 配对；顶层包含 `auth`/`request`/`response`/
`time`/`type` 等关键字段。

第五，敏感字符串字段默认会被 HMAC-SHA256 哈希；非字符串类型不会被哈希；
可通过 `sys/audit-hash` 反查或在 mount tune 中豁免；LIST 大响应体可通过
`elide_list_responses` 选项压缩。

第六，请求 Header 默认仅记录 `User-Agent`、`Correlation-Id`、
`X-Correlation-Id` 三项，可在 `/sys/config/auditing` 中追加并按需打开
HMAC；并存在一份不会被审计的端点豁免清单。

掌握以上六条之后，再进入 8.2「三种内置审计设备配置详解（File / Syslog /
Socket）」与 8.3「最佳实践」时，就能直接聚焦在每种设备自身的差异参数上，
而不必反复回到审计模型本身做铺垫。
