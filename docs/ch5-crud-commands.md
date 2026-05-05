---
order: 51
title: 5.1 核心 CRUD 交互指令：read, write, delete, list, patch 深度应用
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.1 核心 CRUD 交互指令：read, write, delete, list, patch 深度应用

> **核心结论**：`vault read`、`vault write`、`vault delete`、`vault list`、`vault patch` 是 Vault CLI 中最接近 HTTP API 的五个通用动词。它们不替你理解具体机密引擎的业务语义，只负责把“某个路径上的某种动作”发送给 Vault；真正决定读到什么、写入什么、删除什么、能不能列目录、能不能局部更新的，是挂载在该路径上的后端插件。

参考：
- [vault read](https://developer.hashicorp.com/vault/docs/commands/read)
- [vault write](https://developer.hashicorp.com/vault/docs/commands/write)
- [vault delete](https://developer.hashicorp.com/vault/docs/commands/delete)
- [vault list](https://developer.hashicorp.com/vault/docs/commands/list)
- [vault patch](https://developer.hashicorp.com/vault/docs/commands/patch)

---

## 1. 五个命令的统一心智模型

这五个命令可以理解为 Vault CLI 的“原始通用工具箱”：你给出路径，CLI 选择对应 HTTP 方法，Vault 再把请求路由给路径后面的机密引擎、认证方法或系统后端。`read` 读取路径上的数据，`write` 向路径写入数据，`delete` 删除路径上的数据或配置，`list` 列出路径下的 key，`patch` 则只更新你明确给出的字段。

| CLI 命令 | HTTP 包装 | 最常见的用途 | 关键提醒 |
| --- | --- | --- | --- |
| `vault read <path>` | `GET` | 读取机密、生成动态凭据、查看配置 | 默认表格输出，可用 `-format=json` 做自动化 |
| `vault write <path> key=value` | `PUT` 或 `POST` | 写入机密、创建配置、调用创建类 API | API 参数放在路径后面，不带 `-` |
| `vault delete <path>` | `DELETE` | 删除机密或配置对象 | 删除语义由后端决定 |
| `vault list <path>` | `LIST` | 列出某个路径下可见的 key | 列目录，不读取 key 的值 |
| `vault patch <path> key=value` | `PATCH` | 局部更新支持 PATCH 的路径 | 只修改命令行里给出的字段 |

路径不是普通文件路径，而是 Vault 的 API 路由入口。比如 `secret/data/customers`、`auth/token/create`、`pki/roles/example` 都是 API 路径；同样的 `write` 动作，发到 Cubbyhole、Token、PKI、Transit 后端时，含义会完全不同。

![Vault CLI CRUD 命令像五个服务窗口，把路径请求交给对应后端处理](/images/ch5-crud-commands/crud-command-map.png)

---

## 2. 先认 API 路径，再决定是否改用专用子命令

通用命令要求你写出真实 API 路径。官方 `read` 示例中特别说明：如果 KV v2 挂载在 `secret/`，用通用命令读取 `customers` 时路径是 `secret/data/customers`，等价 HTTP 请求是 `GET $VAULT_ADDR/v1/secret/data/customers`。

同一件事也可以用面向 KV 的专用子命令完成：`vault kv get -mount=secret customers` 会读取同一份数据。差别在于输出形态：`vault read` 默认输出 key-value 表格，`curl` 输出 JSON，而 `vault kv get` 针对 KV 引擎做了更容易阅读的结构化展示。

`write` 也有同样的分层。`vault write auth/token/create policies="admin" ttl=8h num_uses=3` 是直接调用 Token API 路径；而常见的令牌创建任务，可以改用 `vault token create -policy=admin -ttl=8h -use-limit=3` 这样的专用子命令。

写命令时要区分两类参数：CLI 命令选项以 `-` 开头，例如 `-ttl`、`-format`；API 路径参数不带 `-`，例如 `ttl=8h`，并且永远放在正在调用的路径后面。

---

## 3. `vault read`：读取数据、配置与动态凭据

`vault read` 是 HTTP `GET` 的 CLI 包装，可用于读取机密、生成动态凭据、查看配置等。官方示例里，它既能读取 Identity Entity 的详情，也能从 AWS 机密引擎的 `aws/creds/my-role` 路径生成动态 AWS 凭据。

```bash
vault read identity/entity/id/<entity-id>
vault read aws/creds/my-role
vault read secret/data/customers
```

默认输出适合人类阅读；做脚本时优先考虑 `-format=json`、`-format=yaml` 或 `-field=<name>`。其中 `-field` 只打印指定字段，并且不会在末尾额外输出换行，方便把结果直接管道给其他进程。

```bash
vault read -format=json auth/token/lookup-self
vault read -field=display_name auth/token/lookup-self
```

`read` 还包含一个 `snapshot-id` 命令选项，用于指定从已经加载的快照 ID 中读取数据。这个能力服务于快照场景，日常 CRUD 训练中先知道它存在即可。

---

## 4. `vault write`：写入数据与调用创建类 API

`vault write` 是 HTTP `PUT` 或 `POST` 的 CLI 包装，可以写入凭据、机密、配置或任意后端接受的数据；具体是创建、更新、配置还是触发动作，由路径上的后端决定。

最普通的输入形式是路径后面的 `key=value`。例如把用户名和密码写进当前令牌的 Cubbyhole，可以直接执行 `vault write cubbyhole/git-credentials username="student01" password="p@$$w0rd"`。

```bash
vault write cubbyhole/git-credentials username="student01" password="p@$$w0rd"
```

如果某个值以 `@` 开头，Vault CLI 会从文件读取这个值；如果某个 key 的值是 `-`，Vault 会从 stdin 读取该值。这两种形式特别适合把策略文件、证书、令牌或脚本输出安全地交给 Vault，而不是把长内容全部写在命令行里。

```bash
vault write aws/roles/ops policy=@policy.json
echo "$MY_TOKEN" | vault write consul/config/access token=-
```

当 API 字段需要 map 等复杂结构时，命令行的 `key=value` 不一定表达得出来。此时可以把 `-` 作为唯一的数据参数，让 `vault write` 从 stdin 读取完整 JSON 请求体；如果同时写了 `key=value`，这个单独的 `-` 会被忽略。

```bash
cat request_payload.json | vault write auth/token/create -
```

有些路径只需要触发动作，不需要请求体，例如创建 Transit key。`-force` 允许 `write` 在没有任何 `key=value` 的情况下继续执行，也可以简写成 `-f`。

```bash
vault write -force transit/keys/my-key
```

`write` 同样支持 `-field` 与 `-format` 输出选项，格式包括 `table`、`json`、`yaml`，也可以通过 `VAULT_FORMAT` 环境变量指定默认输出格式。

---

## 5. `vault list` 与 `vault delete`：列目录和删除对象

`vault list` 是 HTTP `LIST` 的 CLI 包装，用来列出给定路径下的数据 key。官方示例使用 `vault list identity/entity/id` 列出可用 Identity Entity 的 ID；注意它是列 key，不是读取每个 key 的值。

```bash
vault list identity/entity/id
```

`list` 的命令选项包含 `snapshot-id`，用于指定从已加载到集群中的 Raft 快照读取要列出的数据。

`vault delete` 是 HTTP `DELETE` 的 CLI 包装，用于删除给定路径上的机密或配置；删除动作的实际效果同样委托给对应后端。官方示例包括删除静态机密、删除 AWS 角色，以及删除 Transit key。

```bash
vault delete secret/my-secret
vault delete aws/roles/ops
vault delete transit/keys/my-key
```

Transit key 的删除还有额外前提：官方示例提示，必须先把 `deletion_allowed` 参数改为 `true`，key 才能被成功删除。这个例子很好地说明了“同样是 delete，安全边界仍由后端控制”。

`delete` 没有额外命令专属 flags，只有所有命令共享的标准 flags。

---

## 6. `vault patch`：只改你点名的字段

`vault patch` 是 HTTP `PATCH` 的 CLI 包装，用于更新路径上的数据；官方文档描述它可以处理凭据、机密、配置或任意数据，具体行为同样由路径上的挂载对象决定。

`patch` 的输入规则与 `write` 基本一致：可以写 `key=value`，可以用 `@file` 从文件读取值，可以用 `key=-` 从 stdin 读取单个值，也可以把 `-` 作为唯一数据参数从 stdin 读取完整 JSON 请求体。

`patch` 与 `write` 的关键差异是更新范围：官方文档明确说，和 `write` 不同，`patch` 只修改命令行中指定的数据。适合的典型场景是只调整某个配置对象里的一个字段，例如把 PKI role 的 `allow_localhost` 改成 `false`。

```bash
vault patch pki/roles/example allow_localhost=false
```

`patch` 支持 `-field`、`-format` 输出选项，格式包括 `table`、`json`、`yaml`；它也支持 `-force` / `-f`，允许没有 `key=value` 的 patch 操作继续执行。

---

## 7. 什么时候选哪个命令

如果你想“看这个路径返回什么”，先用 `read`；如果你想“看这个路径下面有哪些 key”，用 `list`；如果你想“把一组参数交给这个路径”，用 `write`；如果你想“只改一个对象里的某几个字段”，优先考虑 `patch`；如果你想“移除这个路径代表的对象”，再用 `delete`。

| 目标 | 首选命令 | 示例 |
| --- | --- | --- |
| 查看当前 token 信息 | `read` | `vault read auth/token/lookup-self` |
| 列出 Identity Entity ID | `list` | `vault list identity/entity/id` |
| 创建一个 Token | `write` | `vault write auth/token/create ttl=30m num_uses=1` |
| 局部修改 PKI role | `patch` | `vault patch pki/roles/example allow_localhost=false` |
| 删除 AWS role | `delete` | `vault delete aws/roles/ops` |

熟练以后，你会在两层 CLI 之间来回切换：通用命令帮助你理解 Vault API 的真实路径和 HTTP 动词，专用命令则在高频场景里提供更友好的参数、输出和保护栏。

---

## 8. 互动实验

本节配套了一个完整的 Killercoda 实验，所有命令都在真实 Vault dev server 上执行。你会先用 `read` 与 `list` 建立“路径就是 API 入口”的直觉，再用 `write` 练习 `key=value`、`@file`、stdin JSON 与 `-force`，随后通过 `delete` 观察后端语义，最后用 `patch` 修改 PKI role 的单个字段。

- **Step 1**：用 `read` / `list` 观察路径与输出格式
- **Step 2**：用 `write` 体验 `key=value`、`@file`、stdin 与 `-force`
- **Step 3**：用 `delete` 理解“删除语义由后端决定”
- **Step 4**：用 `patch` 局部更新 PKI role

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-crud-commands" title="实验：核心 CRUD 命令 read / write / delete / list / patch" />
