---
order: 55
title: 5.5 另一些重要命令：lease / unwrap / ssh / path-help
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.5 另一些重要命令：lease / unwrap / ssh / path-help

> **核心结论**：`vault lease ...`、`vault unwrap`、`vault ssh` 与 `vault path-help` 不属于普通 CRUD，也不是专门的 KV 管理命令；它们分别承担四类补充职责：管理动态机密租约、取出响应封装内容、用 SSH 机密引擎生成的凭据发起连接，以及直接从 Vault 路由上读取内置 API 帮助。

参考：

- [vault lease](https://developer.hashicorp.com/vault/docs/commands/lease)
- [vault lease lookup](https://developer.hashicorp.com/vault/docs/commands/lease/lookup)
- [vault lease renew](https://developer.hashicorp.com/vault/docs/commands/lease/renew)
- [vault lease revoke](https://developer.hashicorp.com/vault/docs/commands/lease/revoke)
- [vault unwrap](https://developer.hashicorp.com/vault/docs/commands/unwrap)
- [vault ssh](https://developer.hashicorp.com/vault/docs/commands/ssh)
- [vault path-help](https://developer.hashicorp.com/vault/docs/commands/path-help)

---

## 1. 四组命令的职责边界

`vault lease` 是一组面向“机密租约”的子命令。官方文档将它限定为与 secret attached leases 交互；如果要管理 token 自身的租约，应使用 `vault token` 命令组，而不是把 token 当作普通 secret lease 处理。

`vault unwrap` 面向响应封装后的 wrapping token。它用给定 token 取出被封装的数据；如果命令行没有传入 token，则会尝试解封装当前已认证 token 中保存的数据。官方文档还说明，解封装后的结果与对未封装机密执行 `vault read` 的结果相同。

`vault ssh` 是 SSH 机密引擎的 CLI 入口。它会使用 SSH secrets engine 生成或取得登录凭据，然后调用本机安装的 `ssh` 程序执行连接，因此前提是 SSH 引擎已经挂载并完成配置，客户端本机也有可执行的 `ssh` 命令。

`vault path-help` 是排查路径和学习 API 的辅助命令。Vault 的系统路径、机密引擎和认证方法端点都提供 markdown 格式的内置帮助；该命令从 Vault 当前路由表中读取这些帮助信息，因此特别适合在不确定某个路径支持哪些子路径或参数时使用。

| 命令 | 主要对象 | 常见问题 | 关键提醒 |
| --- | --- | --- | --- |
| `vault lease lookup/renew/revoke` | 动态机密 lease ID | 这份动态凭据还剩多久、能否续期、何时回收 | token 的生命周期由 `vault token ...` 管理 |
| `vault unwrap` | wrapping token | 一次性封装响应如何取出 | 解封装结果等同读取原始响应 |
| `vault ssh` | SSH secrets engine 生成的凭据 | 如何用 Vault 签发的 OTP 或证书登录主机 | 需要已配置 SSH 引擎和本地 `ssh` |
| `vault path-help` | Vault API 路径 | 某条路径支持什么参数和子路径 | 输出来自当前已启用的后端路由 |

![lease、unwrap、ssh 与 path-help 像四个辅助服务台，分别处理租约、封装、远程登录和路径说明](/images/ch5-other-commands/other-command-map.png)

---

## 2. `vault lease`：动态机密的生命周期管理

Vault 动态机密通常带有 lease。`vault lease lookup` 用 lease ID 查询租约信息，输出示例包含 `id`、`issue_time`、`expire_time`、`ttl`、`renewable` 与 `last_renewal` 等字段；这些字段帮助使用者判断凭据从何时签发、何时到期，以及是否还能继续续期。

`lease lookup` 没有专用命令选项，只有所有命令共享的标准选项。实际使用时，最重要的输入是完整 lease ID；官方示例使用了形如 `database/creds/readonly/...` 的 lease ID。

`vault lease renew` 用于续期 secret lease，延长该机密在被 Vault 撤销前可以继续使用的时间。官方文档特别强调，续期不会改变机密内容本身；例如数据库用户名和密码仍是同一组，只是这组凭据的有效时间被延长。

`lease renew` 的 `-increment` 选项表示请求一个具体的续期增量，类型为 duration。该值是请求，不是承诺；官方文档明确说明 Vault 不一定会完全满足该请求。

`vault lease revoke` 用于撤销 secret lease，并使底层机密失效。使用者应把它理解为终止该动态机密生命周期的操作，而不是普通的本地列表删除。

`lease revoke` 支持 `-prefix`，可以把传入 ID 当作前缀并一次撤销多条 lease；官方示例使用 `vault lease revoke -prefix database/creds` 批量撤销该前缀下的租约。这是生产环境中的强操作，执行前应确认前缀范围足够精确。

`lease revoke` 还支持 `-sync` 与 `-force`。`-sync` 要求撤销同步执行，而不是只排入后台队列；`-force` 会在机密引擎撤销失败时仍从 Vault 删除 lease，官方文档说明它面向目标系统中的机密已经被人工删除等恢复场景，并且必须与 `-prefix` 配合使用。

下面是一条典型的 lease 运维路径：先读取动态凭据，保存 `lease_id`；再用 `lookup` 查看 TTL；如果业务仍需使用该凭据，用 `renew` 请求延长；当业务结束或发生风险时，用 `revoke` 主动回收。

```bash
CREDS_JSON=$(vault read -format=json database/creds/readonly)
LEASE_ID=$(jq -r .lease_id <<< "$CREDS_JSON")

vault lease lookup "$LEASE_ID"
vault lease renew -increment=300 "$LEASE_ID"
vault lease revoke "$LEASE_ID"
```

![动态数据库凭据像一张限时通行证，lease lookup 查看剩余时间，renew 延长有效期，revoke 交回通行证](/images/ch5-other-commands/lease-lifecycle.png)

---

## 3. `vault unwrap`：一次性取出响应封装内容

响应封装的核心思想是先交付 wrapping token，而不是直接交付真实响应。`vault unwrap` 接收 wrapping token 并取出其中的数据；官方文档说明，取出的结果与对未封装机密执行 `vault read` 的结果相同。

官方示例给出两种调用方式：可以把 wrapping token 作为参数传给 `vault unwrap <token>`；也可以先把 wrapping token 作为当前登录 token，再直接执行不带参数的 `vault unwrap`，此时命令会解封装 active token 中的数据。

`unwrap` 的输出选项与许多读取类命令一致。`-field` 只打印指定字段，并且不会附加尾随换行，适合把结果传给其他进程；`-format` 可以选择 `table`、`json` 或 `yaml`，也可以通过 `VAULT_FORMAT` 环境变量设置默认输出格式。

下面的示例用通用 `read` 命令生成一个短 TTL wrapping token，再用 `unwrap` 取出被封装的响应。这里的重点是 `vault unwrap <token>` 这个动作：官方文档说明它会解封装给定 token 中的内容，得到的结果与读取未封装机密相同。

```bash
vault kv put secret/training/wrapped username="student" password="temporary"

WRAP_JSON=$(vault read -wrap-ttl=2m -format=json secret/data/training/wrapped)
WRAP_TOKEN=$(jq -r .wrap_info.token <<< "$WRAP_JSON")

vault unwrap "$WRAP_TOKEN"
```

解封装应被理解为“取件”而不是“复制”。在命令层面，`vault unwrap` 的职责不是重新读取原路径，而是使用给定 token 取出其中已经封装好的响应。

---

## 4. `vault ssh`：把 SSH 机密引擎包装成登录命令

`vault ssh` 会使用某个 SSH secrets engine 的角色生成登录凭据，并自动建立到目标主机的 SSH 连接。官方文档列出三种认证模式：`ca`、`dynamic` 与 `otp`，对应 `-mode` 选项的可选值。

OTP 模式的官方示例为 `vault ssh -mode=otp -role=my-role user@1.2.3.4`，并说明如果要完整自动化该模式，需要本机安装 `sshpass`。在教学环境中，可以配合 `-no-exec` 只打印生成的凭据而不真正建立连接，这样便于观察 Vault 与 SSH 引擎之间的交互。

CA 模式的官方示例为 `vault ssh -mode=ca -role=my-role user@1.2.3.4`。该模式通常使用本机公钥向 Vault 申请签名，常用选项包括 `-public-key-path` 与 `-private-key-path`；文档说明私钥路径必须对应要发送给 Vault 签名的公钥路径。

`-mount-point` 用于指定 SSH secrets engine 的挂载点，默认是 `ssh/`；`-role` 指定用于生成凭据的角色；`-strict-host-key-checking` 与 `-user-known-hosts-file` 分别传递给 SSH 配置中的 `StrictHostKeyChecking` 与 `UserKnownHostsFile`，也可以由对应环境变量设置。

CA 模式还可以让 Vault 辅助生成用于主机密钥校验的 `known_hosts` 文件。设置 `-host-key-mount-point` 后，Vault 会使用提供的 SSH secrets engine 挂载点为主机密钥校验生成委派信息；文档说明这会强制 strict key host checking，并忽略自定义 user known hosts file。

下面示例展示两类常见命令形态。第一条使用 OTP 模式并避免真正连接，适合在课程中观察生成结果；第二条展示 CA 模式下显式传入公钥和私钥路径的写法。

```bash
vault ssh -mode=otp -mount-point=ssh-otp -role=training-otp -no-exec vaultlab@127.0.0.1

vault ssh \
  -mode=ca \
  -mount-point=ssh-client-signer \
  -role=training-ca \
  -public-key-path=/root/.ssh/id_rsa.pub \
  -private-key-path=/root/.ssh/id_rsa \
  vaultlab@127.0.0.1
```

---

## 5. `vault path-help`：从当前 Vault 读取 API 说明书

`vault path-help` 的输入是 Vault 路径，而不是本地文件路径。官方文档说明，路径就是 `vault read`、`vault write` 等命令使用的参数，例如 `secret/foo` 或 `aws/config/root`；具体可用路径取决于当前启用的机密引擎和认证方法。

该命令最有价值的场景是发现当前后端支持哪些路径。官方文档建议对已启用的后端执行 `vault path-help PATH`；例如启用 AWS 机密引擎后，可以用 `vault path-help aws` 查看该后端支持的路径。

`path-help` 输出的路径可能以正则表达式形式展示。官方文档提醒这些正则表达式有时不容易阅读，但非常精确；找到匹配的路径模式之后，可以继续对更具体的路径执行 `vault path-help <path>` 来查看参数和描述。

`path-help` 没有除标准选项外的专用 flag。也就是说，使用者主要通过改变传入路径来改变查询对象，而不是通过命令选项选择不同模式。

下面是一条从粗到细的探索路径。先查看某个后端的总体帮助，再查看具体凭据签发路径；如果输出中出现 `PARAMETERS`，就可以据此判断 `write` 或 `read` 请求需要哪些字段。

```bash
vault path-help database
vault path-help database/creds/readonly
vault path-help sys/leases/lookup
```

---

## 6. 互动实验

本节配套实验会在一个 Vault dev server 中完成五组操作：使用 `path-help` 读取当前后端的路径说明；生成 PostgreSQL 动态凭据并用 `lease lookup`、`lease renew`、`lease revoke` 管理它的生命周期；用 `-prefix` 和 `-sync` 批量回收同一前缀下的租约；创建 response wrapping token 并用 `vault unwrap` 取出内容；最后配置一个最小 SSH OTP 角色，用 `vault ssh -no-exec` 观察 Vault 为 SSH 登录生成的凭据。

- **Step 1**：使用 `vault path-help` 查看后端和具体路径的内置帮助。
- **Step 2**：读取动态数据库凭据，并对其 lease 执行查询、续期与撤销。
- **Step 3**：生成多条动态凭据，使用 `lease revoke -prefix -sync` 批量回收。
- **Step 4**：用响应封装交付一份 KV 响应，再用 `vault unwrap` 一次性取出。
- **Step 5**：用 `vault ssh -mode=otp -no-exec` 观察 SSH OTP 凭据生成。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-other-commands" title="实验：lease / unwrap / ssh / path-help 重要命令实战" />
