---
order: 93
title: 9.3 用 Vault Agent 缓存为高频读请求降压：动态租约复用与 token 续期托管
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.3 用 Vault Agent 缓存为高频读请求降压：动态租约复用与 token 续期托管

> **核心结论**：Vault Agent 内置的缓存（Caching）功能，**只缓存两类响应**——通过 Agent 发起的『新建 Token』请求，以及**用 Agent 已经管着的 Token** 通过 Agent 发起的『新建带租约（lease）机密』请求；并由 Agent 在内存中代为续期这些 Token 与租约。它**不会缓存** KV v1 / KV v2 这类静态机密的读取响应——这类工作流官方明确建议改用 Vault Proxy 的 static secret caching 完成。本节先把这条边界讲清楚，再用一份运行在 LocalStack 上的 AWS 动态 IAM 凭据实验，让学员在终端里亲眼看到『同一个客户端连续两次问 Agent 要凭据，第一次落到 Vault 创建一个新 IAM User、第二次直接从 Agent 内存里返回同一份租约』——这就是 Agent 缓存为 Vault 集群降压的真实形态。

参考：

- [Vault Agent caching overview — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/caching)
- [Vault Agent caching tutorial — HashiCorp Tutorials](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-caching)
- [Use built-in persistent caching — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/caching/persistent-caches)
- [Vault Proxy static secret caching — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/proxy/caching/static-secret-caching)
- 已学衔接：[7.2 Vault Agent](/ch7-agent)（Auto-auth 与模板渲染主线）、[5.6 Vault Proxy](/ch5-vault-proxy)（独立代理与静态机密缓存）、[3.3 AWS 机密引擎](/ch3-aws-engine)（动态 IAM 凭据与租约）、[2.3 租约（Lease）](/ch2-lease)（租约生命周期）

---

## 1. 这一节解决的问题：被高频读拖垮的不是 Vault，是『没缓存』

在生产环境中，一个常见的运维事故链条是这样的：业务高峰期，某个微服务集群被横向扩容到几百个 Pod，每个 Pod 启动时都需要向 Vault 拿一份数据库动态凭据；几百个并发的『新建租约』请求同时打到 Vault 集群，叠加每分钟的常规读取，把 Vault 的 P99 延迟推到秒级，进而把整条业务读链路拖入超时风暴。这类故障的根因不是 Vault 不够快，而是**架构里压根没有给『同一个应用实例反复要同一份机密』这种行为留缓存层**。

Vault Agent 的 Caching 功能就是为这条缝隙设计的：把缓存层下沉到**应用所在的本机进程**，让同一份动态租约在它合法 TTL 内**只向 Vault 申请一次**，后续重复请求由 Agent 在内存里直接命中返回；并且 Agent 还会**自动替你续期**这些 Token 与租约，应用代码完全不需要写续期逻辑。

但要把这件事用对，必须先把 Agent 缓存的**真实边界**讲清楚——它绝不是『万能本地缓存』，它有一份非常窄的『只缓存这两类响应』清单。这正是本节的第一项任务。

---

## 2. Agent 缓存的真实边界：只缓存『新创建的 Token』与『新建的租约机密』

官方文档对 Agent 缓存的范围给出了**两条且仅两条**的明确边界：

1. **新创建 Token 的响应会被缓存**——只要这次 Token 创建请求是经过 Agent 转发的，就会被纳入 Agent 的缓存。换言之，任何登录类请求（`auth/<method>/login`）以及 `auth/token/create` 端点的调用，只要走的是 Agent，Agent 都会把响应里那枚新 Token 放进自己的缓存。需要补充的是：在 Token 创建场景中，新 Token 之所以能落进 Agent 缓存，前提是它的『父 Token』本身已经被 Agent 管着，或者新 Token 是孤儿 Token（orphan）。
2. **用 Agent 已管着的 Token 创建的『带租约机密』响应也会被缓存**——典型例子就是用 Agent 持有的 Token 调一次 `aws/creds/<role>` 或 `database/creds/<role>`，这类调用会让 Vault 创建一份新的 IAM User 或一行新的数据库账号并返回一份带 `lease_id` 的响应；Agent 会把这份响应缓存下来，并接管它的续期。

落在这两条之外的请求 Agent 不会做语义级缓存。最容易让初学者踩坑的反例是 **KV v1 / KV v2** 这类静态机密：官方在 Caching 文档的开头就用一条醒目的提示明确说明，**Vault Agent 不支持通过 API proxy 对静态机密做缓存**；如果你的目标是减少静态 KV 请求转发到 Vault 的次数，应该使用 **Vault Proxy 的 static secret caching** 功能，而不是 Vault Agent。本书 5.6 节已经独立讲过 Vault Proxy 的相关用法，本节不再重复。

请把这条边界**当作一条物理定律来记忆**：要缓存什么决定了选哪一个工具。

| 想缓存的东西 | 选谁 | 走哪个产品 |
| --- | --- | --- |
| 自己持有的 Vault Token、以及用它创建的动态租约（DB / AWS / PKI / SSH 等带 lease 的机密） | Vault Agent Caching | 本节 |
| KV v1 / KV v2 等无租约的静态机密的读响应 | Vault Proxy static secret caching | [5.6 节](/ch5-vault-proxy) |

---

## 3. 续期托管：Agent 帮你做的事，与它故意不做的事

Agent 缓存的第二项核心价值是『续期托管（renewal management）』。官方文档说得相当清楚：Agent 使用 Vault Server Go API 中的 secret renewer 在**纯内存**中续期所有被缓存的 Token 与租约；它**不持久化任何东西到存储**，也就意味着 Agent 进程一旦关闭，所有续期协程立即终止；Agent 关闭这件事**本身并不代表撤销机密**，它只是从此不再为这些尚未撤销的有效机密做续期工作。

这条设计原则有两个直接后果，必须告诉学员：

- **Agent 进程异常退出 ≠ 业务凭据立刻失效**：Agent 退出后，业务侧已经拿在手里的那枚动态凭据在它原本的 TTL 内仍然能正常使用，直到 TTL 到期或被人显式撤销；
- **但是从 Agent 退出那一刻起，就再也没有人替这些凭据自动续期**：如果业务依赖『隐式的长期有效』，重启 Agent 之前必须先重新登录并重新申请一次凭据，否则会等到 TTL 到了才发现一切都过期了。

Agent 也会**尽力（best-effort）做缓存条目的驱逐**：当机密达到 maximum TTL、续期持续报错时，对应缓存条目会被驱逐；如果一个 Token 撤销请求或 lease 撤销请求经由 Agent 转发并被 Vault Server 成功处理，Agent 也会把对应的缓存条目剔除。但请注意一种 Agent 完全感知不到的情况：**如果客户端绕过 Agent 直接向 Vault Server 发起撤销**，Agent 不知道这次撤销发生过，缓存里的对应条目会变成『陈旧条目（stale entry）』；为这种情况官方提供了一个 `/agent/v1/cache-clear` 端点用于手动清理。

---

## 4. 让缓存能被使用：`cache` 块、`listener` 块、`use_auto_auth_token`

要把 Agent 缓存真正用起来，配置文件里至少要做三件事——开启缓存、暴露一个监听口让客户端经过它走、以及把 Auto-auth 取得的 Token 喂给缓存当『默认 Token』。

**第一件事，开启缓存**。在配置文件顶层放一个 `cache` 块即可激活缓存功能；官方文档明确说明：**只要顶层出现 `cache` 块（哪怕是个空块），缓存就会被启用**。

**第二件事，让客户端真的走到 Agent**。官方文档同样明确：当 `cache` 块被定义时，**配置里至少还要再定义一个 `template` 或一个 `listener`**，否则缓存根本没办法被使用。本节实验走的是『客户端 HTTP 请求经过 Agent listener → Agent 命中或回源 → 返回响应』这条主路径，所以一定要配 `listener`。

**第三件事，让 Agent 用 Auto-auth 拿到的 Token 替客户端带上**。`cache` 块里的 `use_auto_auth_token` 选项控制：当客户端没在 HTTP 请求里带 `X-Vault-Token` 头时，Agent 是否要用 Auto-auth 拿到的那枚 Token 替它带上去。打开它之后，应用代码里**完全不需要管 Token 从哪来**，把 `VAULT_ADDR` 指向 Agent listener、`VAULT_TOKEN` 留空即可。

下面是本节实验里实际使用的最小配置骨架，覆盖上面三件事：

```hcl
pid_file = "/tmp/vault-agent-cache.pid"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/agent-role-id"
      secret_id_file_path                 = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/root/agent-cache/auto-auth-token"
    }
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
```

> Auto-auth 的语义本身已经在 [7.2 节](/ch7-agent) 完整讲过；本节只关心它的产物——Agent 持续持有的一枚有效 Vault Token，并把这枚 Token 同时用于『缓存命中匹配』和『为客户端带上 X-Vault-Token 头』。

---

## 5. CLI 怎么把请求打到 Agent listener：`VAULT_AGENT_ADDR`

把 `VAULT_ADDR` 直接指向 Agent listener 当然能用，但生产里通常还要保留『管理员偶尔直连 Vault Server』的能力。Vault CLI 为这种情况提供了一个独立环境变量 `VAULT_AGENT_ADDR`，专门指向 Agent listener，例如 `"http://127.0.0.1:8100"`；CLI 会从这个变量读出 Agent 地址。配合上一节 `use_auto_auth_token = true`，应用侧只要把请求发到 `VAULT_AGENT_ADDR`、且不带 `X-Vault-Token` 头，Agent 就会替它把 Auto-auth Token 贴上去并接管整条请求-响应路径。

本节实验为了让学员一眼看清『请求究竟走没走 Agent』，会**显式**用 `curl -X GET http://127.0.0.1:8100/v1/aws/creds/...` 直接打 Agent listener，再用 `--request POST http://127.0.0.1:8100/agent/v1/cache-clear` 打 Agent 的运维接口；CLI 自身不参与缓存命中观察，避免把『CLI 的 token helper』与『Agent 的缓存』两件事搅在一起。

---

## 6. `cache-clear` 运维端点：手动驱逐特定缓存条目

当上一节那种『绕过 Agent 直接撤销』导致缓存条目变陈旧时，运维需要一个手动驱逐缓存的入口。Agent 在 listener 上额外暴露了一个 `POST /agent/v1/cache-clear` 端点用于这件事。它接受两个必填参数与一个可选参数：

- `type`（必填，字符串）：要驱逐的缓存条目类型，**合法取值** 为 `request_path`、`lease`、`token`、`token_accessor`、`all` 这五种；当 `type=all` 时整个缓存被清空；
- `value`（必填，字符串）：与 `type` 配套使用的精确值或前缀；当 `type=all` 时该字段可省略；
- `namespace`（可选，字符串）：仅当 `type=request_path` 时适用，用于指定要驱逐的请求路径所在的 namespace。

文档同时给出了一个**官方示例 payload**：

```json
{
  "type": "token",
  "value": "hvs.<REDACTED-EXAMPLE-TOKEN>"
}
```

以及对应的 `curl` 调用方式：

```bash
curl --request POST --data @payload.json http://127.0.0.1:1234/agent/v1/cache-clear
```

> 文档同时指出：**对于没有启用 caching 的 listener**，这个 API 端点仍然存在并可访问，只是不会做任何事，只会返回 `200`。

---

## 7. 请求唯一性的判定方式：哈希整个 HTTP 请求

很多初学者第一次用 Agent 缓存时，会问『两次请求只有一个 query 参数顺序不同，能算同一次吗？』。官方文档给出的答案是直白的『**不算**』。Agent 当前用以判定请求是否相同的方法，是把整个 HTTP 请求**连同所有 header 与 body 在内**做序列化与哈希，并以这个哈希值作为缓存索引；任何对请求内容的改动都会改变哈希值，包括请求参数顺序的变化都会被视作不同的请求，进而**产生重复的缓存条目**。

工程上的含义只有一句：**让你的客户端使用一致的方式发请求**——不要每次随机化 header 顺序、不要每次换种方式拼 query string；做到这一点，缓存命中行为才会稳定。这一点也是官方明确指出的：缓存功能是建立在『客户端会用一致机制发请求』这一启发式假设之上的。

---

## 8. Persistent cache：现阶段只服务于 Kubernetes 边车场景

Agent 还提供一个 **Persistent cache（持久化缓存）** 选项，允许新启动的 Agent 进程从前一个 Agent 进程留下的缓存文件中**恢复 Token 与 lease**，而不必重新走一次 Auto-auth。它通过在 `cache` 块里嵌一个 `persist` 子块开启。

但请注意它**目前的边界非常窄**：官方文档明确写明，`persist.type` 当前**只支持 `kubernetes` 一种取值**。在 Kubernetes 持久化缓存模式下，ServiceAccount Token 会参与缓存文件的加密与解密完整性校验；官方建议这种模式**只用于 init Agent container 与 sidecar Agent container 之间通过 memory volume 共享 Vault Token 和 lease**。

也就是说：在裸机 / VM / 普通容器环境下，Persistent cache **没有可用类型**——这种场景下『Agent 重启 = 缓存清零，重新 Auto-auth + 重新申请租约』，是 Agent 缓存机制必须接受的硬约束。这也意味着它不是『把缓存做到磁盘上避免单点』的方案，而是专为 K8s 边车注入的 init/sidecar 接力问题量身定制的过渡机制。需要在裸机环境横向扩缓存层、在 Vault 故障窗口里继续供给机密的场景，应该走 [Vault Proxy](/ch5-vault-proxy) 或 [Vault Secrets Operator (VSO)](/ch7-vso) 这条路线。

---

## 9. 选型小结：什么时候真的需要 Agent 缓存

把上面所有要点合起来，可以给学员一份直接可用的选型清单：

1. **业务里有大量短 TTL 动态凭据（DB / AWS / PKI / SSH 等带 lease 的机密）**：Agent 缓存的主战场——用一个 Agent 进程托管 Token 与租约，把『同一应用实例的同一份租约』压缩为对 Vault 的一次创建；
2. **业务主要是反复读 KV 静态机密**：**不是** Agent 缓存的目标场景——选 Vault Proxy 的 static secret caching（[5.6 节](/ch5-vault-proxy)）；
3. **要在 Vault 故障窗口里继续供给机密、或要在多个应用实例间共享缓存**：Agent 缓存做不到（关进程即丢、且只服务本机）——选 Vault Proxy（独立网关共享缓存）或 VSO（把机密物化为 K8s Secret 解耦生命周期）；
4. **裸机 / VM 环境下追求『Agent 重启不丢缓存』**：现阶段没办法——Persistent cache 仅支持 `kubernetes` 类型；接受『重启即重新 Auto-auth』这一约束，或换 Vault Proxy。

掌握这份清单后，可在动手实验里亲自把一个 Vault Agent 接到 LocalStack 上的 AWS 动态 IAM 凭据流程上，依次复现『连续两次问 Agent 要凭据 → 第二次直接命中 → 用 cache-clear 驱逐 → 第三次重新落到 Vault 创建新 IAM User』这一闭环。

---

## 10. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 主机上启动 dev 模式的 Vault、LocalStack（模拟 AWS API），并启动一个开启了 caching 的 Vault Agent，依次完成『启用并配置 AWS 机密引擎与 AppRole Auto-auth → 启动带 cache + listener 的 Agent → 通过 Agent 连续两次申请 IAM 凭据观察缓存命中 → 用 `cache-clear` 端点驱逐特定 lease 后再次申请 → 验证静态 KV 不会被缓存』五段操作。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-agent-cache" title="实验：用 LocalStack + AWS 动态凭据演示 Vault Agent Caching" />
