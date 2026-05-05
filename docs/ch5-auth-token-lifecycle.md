---
order: 52
title: 5.2 认证与生命周期管控：login, auth, token 复杂参数体系
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.2 认证与生命周期管控：login, auth, token 复杂参数体系

> **核心结论**：`vault login`、`vault auth ...`、`vault token ...` 分别位于认证流程的三个层面：`login` 使用某种认证方法取得 Vault token，`auth` 管理认证方法本身的挂载与调优，`token` 管理已经签发出的 token 的创建、查询、续期、能力检测与撤销。三者都与“认证”有关，但职责边界完全不同。

参考：

- [vault login](https://developer.hashicorp.com/vault/docs/commands/login)
- [vault auth](https://developer.hashicorp.com/vault/docs/commands/auth)
- [vault auth enable](https://developer.hashicorp.com/vault/docs/commands/auth/enable)
- [vault auth disable](https://developer.hashicorp.com/vault/docs/commands/auth/disable)
- [vault auth help](https://developer.hashicorp.com/vault/docs/commands/auth/help)
- [vault auth list](https://developer.hashicorp.com/vault/docs/commands/auth/list)
- [vault auth move](https://developer.hashicorp.com/vault/docs/commands/auth/move)
- [vault auth tune](https://developer.hashicorp.com/vault/docs/commands/auth/tune)
- [vault token capabilities](https://developer.hashicorp.com/vault/docs/commands/token/capabilities)
- [vault token create](https://developer.hashicorp.com/vault/docs/commands/token/create)
- [vault token lookup](https://developer.hashicorp.com/vault/docs/commands/token/lookup)
- [vault token renew](https://developer.hashicorp.com/vault/docs/commands/token/renew)
- [vault token revoke](https://developer.hashicorp.com/vault/docs/commands/token/revoke)

---

## 1. 三组命令的职责边界

`vault login` 是“取得会话凭据”的命令。它接收用户或机器提交的认证材料，认证成功后返回一枚 Vault token；默认情况下，这枚 token 会被缓存到本机 token helper 中，后续 CLI 请求可以自动使用它。这里的 token 可以类比为网站登录后的 session token：它不是原始密码，而是登录成功后由 Vault 签发的访问凭据。

`vault auth` 是“管理登录入口”的命令组。它用于列出、启用、禁用、查看帮助、迁移和调优认证方法；官方文档明确提醒，真正执行认证登录时应使用 `vault login`，而不是 `vault auth` 本身。

`vault token` 是“管理已签发凭据”的命令组。本节聚焦五个高频子命令：`create` 创建 token，`lookup` 查询 token 或 accessor，`renew` 延长 token 租约，`revoke` 撤销 token 及其子级，`capabilities` 检查某枚 token 在某条路径上的能力。

| 场景 | 首选命令 | 直接对象 | 结果 |
| --- | --- | --- | --- |
| 用户或机器要登录 Vault | `vault login` | 外部凭据或已有 token | 取得并可缓存 Vault token |
| 管理员要启用或调整登录方式 | `vault auth ...` | auth method 挂载点 | 改变认证方法配置 |
| 管理员或程序要管理 token 生命周期 | `vault token ...` | token 或 accessor | 创建、查询、续期、撤销或检查能力 |

![login、auth 与 token 三组命令的职责分层](/images/ch5-auth-token-lifecycle/login-auth-token-map.png)

---

## 2. `vault login`：从认证材料换取本地可用 token

`vault login` 默认使用 `token` 方法，并从标准输入读取 token；也可以把 token 直接写成命令行参数，但官方示例提醒，这种写法可能被 shell 历史或进程列表记录，因此不适合处理敏感凭据。

使用其他认证方法时，应通过 `-method` 指定认证类型，例如 `userpass`、`ldap` 或 `cert`。这些方法通常还需要额外的 `K=V` 参数；如果不确定某个方法需要哪些参数，可以先执行 `vault auth help TYPE`，也可以用 `vault auth list` 查看当前已经启用的认证方法。

需要特别区分 `-method` 与 `-path`：`-method` 表示认证方法的规范类型，`-path` 表示该认证方法在 Vault 中实际启用的路径。如果 GitHub 认证方法挂载在 `github-prod/` 而不是默认路径，登录命令仍写 `-method=github`，同时通过 `-path=github-prod` 指向实际挂载点。

默认登录成功后，CLI 会把 token 存入 token helper，便于后续请求自动使用。`-no-store` 会阻止 token 持久化到本地 helper，只把 token 显示在当前命令输出中；`-no-print` 则不在屏幕上显示 token，但仍会存入配置的 token helper。两者分别服务于“只临时拿 token”和“减少屏幕泄露”的不同需求。

自动化脚本常用 `-token-only`，它等价于 `-field=token -no-store` 的快捷形式，只输出 token 字符串，不把它写入本地 helper。需要注意，官方文档说明该选项输出 token 时不做额外验证，因此它适合在已经信任登录请求结果的脚本中使用。

`login` 也支持 `-field` 与 `-format` 输出控制。`-field=<name>` 只打印指定字段且末尾不额外添加换行，适合管道传递；`-format` 可以指定 `table`、`json` 或 `yaml`，也可以通过 `VAULT_FORMAT` 环境变量设置默认格式。

如果登录请求使用响应封装，例如通用 `-wrap-ttl` 标准参数，`vault login` 默认会自动解封装并得到真实 token；但当使用 `-token-only` 时会输出 wrapping token，当使用 `-no-store` 时会输出 wrapping token 的详细信息。这个差异在交接一次性凭据时非常重要。

---

## 3. `vault auth`：管理认证方法挂载点

`vault auth enable TYPE` 会在指定路径启用一种认证方法；如果该路径已经存在认证方法，命令会返回错误。认证方法启用后通常还需要按具体方法继续配置，因为不同方法的配置项并不相同。

默认情况下，启用路径等于认证方法类型，例如 `vault auth enable userpass` 会使该方法可通过 `/auth/userpass` 访问。通过 `-path=<path>` 可以指定唯一的自定义路径；同一种认证类型因此可以被多次挂载到不同路径，分别服务不同人群或环境。

启用时可以同时设置一部分通用挂载参数，例如 `-description`、`-default-lease-ttl`、`-max-lease-ttl`、`-token-type`、`-listing-visibility`、请求/响应头透传、审计日志非 HMAC 字段、`-seal-wrap`、`-trim-request-trailing-slashes` 与 `-plugin-version`。这些参数属于挂载点层面的基础运行配置，不替代具体认证方法自己的业务配置。

`vault auth list` 用于列出已启用的认证方法；加上 `-detailed` 后会显示更详细的配置、复制状态、Accessor、TTL、Token Type、UUID、插件版本与运行版本等信息。官方文档还说明，从 Vault 1.12 起，内置认证引擎会显示弃用状态，非内置插件的弃用状态显示为 `n/a`。

`vault auth help` 用于查看某个认证方法的登录用法。传入 TYPE 时，它打印该类型的默认帮助；传入 PATH 时，它打印已经启用在该路径上的认证方法帮助，并且该路径必须已经存在。每一种认证方法都会产生自己的帮助输出。

`vault auth tune PATH` 用于调整已经启用的认证方法挂载点配置。官方文档特别提示，该参数对应的是认证方法被启用的路径，而不是认证类型；例如调优自定义路径 `staff/` 上的 userpass，应写 `vault auth tune ... staff/`，而不是只凭类型写 `userpass`。

常见调优项包括默认 TTL、最大 TTL、描述、Token Type、是否在 UI 列表中可见、允许响应头、透传请求头、审计字段 HMAC 例外以及插件版本。`-max-lease-ttl` 可以高于或低于服务器全局最大 TTL；如果要把某个 TTL 调回系统默认值，可以按官方示例传入 `-1`。

`auth tune` 还可以配置用户锁定参数，包括失败次数阈值、锁定时长、计数器重置时长以及禁用用户锁定。官方文档说明，用户锁定功能只支持 `userpass`、`ldap` 与 `approle` 三类认证方法，因此不要把这些参数误认为所有认证方法都能生效。

`vault auth disable PATH` 会禁用指定路径上的认证方法；该命令是幂等的，即使路径上没有认证方法也会成功返回。更关键的是，禁用后该方法不能再用于认证，并且所有通过该方法签发的访问 token 会立即被撤销，命令会阻塞直到撤销完成。

`vault auth move SOURCE DESTINATION` 用于把已有认证方法迁移到新路径，底层会触发 remount 操作，并使用返回的 migration ID 轮询到 `success` 或 `failure` 终态。官方文档同时警告，旧认证方法相关的租约会被撤销，但配置会被保留；跨命名空间移动时，还要确认目标命名空间中的策略、实体和组是否需要同步调整。

---

## 4. `vault token create`：创建 token 时的参数分组

`vault token create` 会创建一枚可用于认证的新 token。默认情况下，新 token 是当前已认证 token 的子 token；除非显式指定策略子集，否则会继承当前 token 的所有策略和权限。

策略相关参数首先看 `-policy` 与 `-no-default-policy`。`-policy` 可以多次指定，为 token 附加多个策略；`-no-default-policy` 用于从该 token 的策略集合中移除 `default` 策略。

生命周期相关参数主要包括 `-ttl`、`-explicit-max-ttl`、`-period`、`-renewable` 与 `-use-limit`。`-ttl` 设置初始 TTL；`-explicit-max-ttl` 设置不可超过的硬性最大生命周期；`-period` 使每次续期都使用指定周期，且只要持续续期就不会过期，除非同时设置了 `explicit-max-ttl`，并且设置该参数需要 sudo 权限；`-renewable` 控制 token 是否可续期；`-use-limit` 设置 token 可使用次数，最后一次使用后会自动撤销。

类型与层级相关参数包括 `-type`、`-orphan` 与 `-role`。`-type` 可以选择 `service` 或 `batch`；`-orphan` 创建没有父级的 token，避免它在创建者 token 过期时被连带撤销，但该选项需要 sudo 权限；`-role` 表示基于 token role 创建 token，且本地认证 token 必须有 `auth/token/create/<role>` 权限，role 也可能覆盖命令行中提供的其他参数。

审计与身份辅助参数包括 `-display-name`、`-metadata` 与 `-entity-alias`。`-display-name` 是非敏感标识，用于帮助识别创建出的凭据；`-metadata` 可以多次指定任意 `key=value` 元数据，并会在该 token 被使用时写入审计日志；`-entity-alias` 只与 `-role` 配合使用，且对应 alias 必须列在 `allowed_entity_aliases` 中。

安全敏感参数包括 `-id` 与 `-wrap-ttl`。`-id` 允许指定 token 值，但需要 sudo 权限，日常实践应优先使用自动生成值；`-wrap-ttl` 会把响应封装进带 TTL 的 cubbyhole token，之后通过 `vault unwrap` 取出真实响应，也可以用 `VAULT_WRAP_TTL` 环境变量指定。

输出控制仍然遵循 CLI 的通用习惯：`-field` 只打印指定字段且不带尾随换行；`-format` 支持 `table`、`json` 与 `yaml`，也可以由 `VAULT_FORMAT` 指定默认值。

---

## 5. `lookup` 与 `capabilities`：查询 token 状态和权限

`vault token lookup` 用于显示 token 或 accessor 的信息。不传 TOKEN 时，它查询本地当前已认证 token；传入 token 值时，它查询指定 token；加上 `-accessor` 时，它把参数当作 accessor，而不是 token。

通过 accessor 查询时，输出不会包含真实 token 值。这一点适合运维系统保存 accessor 而非保存 token 明文：系统仍可查状态、续期或撤销，但不能把 accessor 当作访问 Vault 的凭据使用。

`vault token capabilities` 用于查询某枚 token 在给定路径上的能力。如果显式传入 token 值，该命令使用 `/sys/capabilities` 端点；如果不传 token 值，则对本地当前 token 使用 `/sys/capabilities-self`。输出示例可能是 `read`，也可能是 `deny`，分别表示允许读取或没有对应路径权限。

能力检测只回答“这枚 token 对这条路径有什么能力”，不代替真正的读写操作。它常用于排查 403 错误：先确认路径是否写对，再观察输出是类似官方示例中的 `read`，还是 `deny` 这样的拒绝结果。

---

## 6. `renew` 与 `revoke`：生命周期的延长与终止

`vault token renew` 会续期 token 的租约，延长它可被使用的时间。不传 TOKEN 时，它续期本地当前已认证 token；如果 token 不可续期、已经被撤销，或者已经达到最大 TTL，续期会失败。

`-increment` 用于请求一个具体的续期期限，也可简写为 `-i`；如果不提供，Vault 使用默认 TTL。官方文档说明，Vault 不会对 periodic token 尊重这个 increment 请求，因为 periodic token 的每次续期使用自身 period。

`-accessor` 允许使用 accessor 而非 token 值进行续期。官方文档指出，accessor 能执行有限管理操作而无需接触敏感 token 明文；使用 `-accessor` 时，输出不会包含 token。

`--fail-if-not-fulfilled` 要求 Vault 在无法完全满足请求的 TTL 增量时失败。这个选项适合自动化脚本：如果续期已被最大 TTL 截断，脚本可以立即转入重新登录流程，而不是误以为 token 已按预期延长。

`vault token revoke` 用于撤销认证 token 及其子 token。不传 TOKEN 时，它撤销本地当前 token；默认模式会撤销目标 token 及其所有子 token。由于撤销会直接终止访问能力，生产环境中应优先用 accessor 或明确 token 参数执行，避免误撤当前操作会话。

`revoke` 的 `-mode` 可以改变撤销范围。默认模式撤销 token 及其所有子级；`-mode=orphan` 只撤销目标 token，使子 token 留作 orphan；`-mode=path` 会删除由给定认证路径前缀创建的 token，并连同它们的子级一起删除。

`-accessor` 让 `revoke` 把参数当作 accessor，`-self` 则撤销当前已认证 token。两者都是强操作：前者适合调度系统远程回收某个任务的 token，后者适合明确执行“登出当前会话”。

---

## 7. 一条标准运维路径

下面这组命令展示了管理员从启用认证入口，到登录、诊断权限、续期、撤销的完整路径。它不是唯一写法，但覆盖了本节最常用的命令边界。

```bash
# 1. 启用一个自定义路径的 userpass 认证方法
vault auth enable -path=staff -description="Training user login" userpass

# 2. 调整该挂载点的 token TTL 和 user lockout 基线
vault auth tune \
  -default-lease-ttl=30m \
  -max-lease-ttl=4h \
  -user-lockout-threshold=5 \
  -user-lockout-duration=15m \
  staff/

# 3. 查看启用状态和登录帮助
vault auth list -detailed
vault auth help staff/

# 4. 创建用户后登录；-token-only 不写入本地 token helper
vault write auth/staff/users/alice password="correct-horse" token_policies="app-read"
ALICE_TOKEN=$(vault login -method=userpass -path=staff -token-only username=alice password=correct-horse)

# 5. 查询 token，并检查它对某条路径的能力
vault token lookup "$ALICE_TOKEN"
vault token capabilities "$ALICE_TOKEN" secret/data/app/config

# 6. 续期或撤销
vault token renew -increment=15m "$ALICE_TOKEN"
vault token revoke "$ALICE_TOKEN"
```

这条路径体现了三个层面的分工：`auth enable/tune/help/list` 调整“入口”，`login` 使用入口换 token，`token lookup/capabilities/renew/revoke` 管理已经发出去的 token。只要把这三层分开，后续学习 LDAP、Kubernetes、OIDC、TLS Cert 或云平台 IAM 认证方法时，命令结构就不会混乱。

---

## 8. 互动实验

本节配套实验会在一个 Vault dev server 中完成五组操作：先启用自定义 `staff/` userpass 认证方法并调优 TTL 与用户锁定参数，再用 `vault login` 获取不落盘 token，随后创建教学 token 并用 `lookup` 与 `capabilities` 排查权限，接着通过 token 与 accessor 分别续期和撤销，最后禁用 auth method，观察通过该方法签发的 token 被批量撤销。

- **Step 1**：启用和调优认证方法挂载点。
- **Step 2**：使用 `vault login` 获取不写入本地 helper 的 token。
- **Step 3**：创建 token，并用 `lookup` 与 `capabilities` 诊断权限。
- **Step 4**：用 token 值和 accessor 续期、撤销 token。
- **Step 5**：禁用认证方法，观察由该方法签发的 token 被撤销。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-auth-token-lifecycle" title="实验：login / auth / token 认证与生命周期命令实战" />
