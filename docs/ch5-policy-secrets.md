---
order: 53
title: 5.3 访问策略与底层引擎挂载管理：policy, secrets 生命周期运维
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.3 访问策略与底层引擎挂载管理：policy, secrets 生命周期运维

> **核心结论**：`vault policy ...` 管理 Vault 中的命名策略对象，命令文档覆盖写入、读取、列出、删除和本地格式化；`vault secrets ...` 管理机密引擎的启用、盘点、迁移、调优和禁用。本节把二者放在同一条运维流程中学习：先理解挂载点如何出现、变化和消失，再理解策略对象如何被上传、查看和删除。

参考：

- [vault policy](https://developer.hashicorp.com/vault/docs/commands/policy)
- [vault policy write](https://developer.hashicorp.com/vault/docs/commands/policy/write)
- [vault policy read](https://developer.hashicorp.com/vault/docs/commands/policy/read)
- [vault policy list](https://developer.hashicorp.com/vault/docs/commands/policy/list)
- [vault policy delete](https://developer.hashicorp.com/vault/docs/commands/policy/delete)
- [vault policy fmt](https://developer.hashicorp.com/vault/docs/commands/policy/fmt)
- [vault secrets](https://developer.hashicorp.com/vault/docs/commands/secrets)
- [vault secrets enable](https://developer.hashicorp.com/vault/docs/commands/secrets/enable)
- [vault secrets list](https://developer.hashicorp.com/vault/docs/commands/secrets/list)
- [vault secrets tune](https://developer.hashicorp.com/vault/docs/commands/secrets/tune)
- [vault secrets move](https://developer.hashicorp.com/vault/docs/commands/secrets/move)
- [vault secrets disable](https://developer.hashicorp.com/vault/docs/commands/secrets/disable)

---

## 1. 先区分两个管理平面

`policy` 命令组用于与 Vault 中的策略交互，常见操作包括写入、读取、列出和删除策略；`fmt` 则作用于本地策略文件，用来把文件格式化为符合策略规范的形式。

`secrets` 命令组用于与 Vault 的机密引擎交互。官方文档提醒，每一种机密引擎的行为并不相同：有的持久保存数据，有的只是把请求透传给外部系统，有的会生成动态凭据；因此，挂载完成后通常还需要继续执行该引擎自己的配置步骤。

本教程采用的练习顺序是：先通过 `vault secrets enable` 启用一个路径上的机密引擎，再通过 `vault policy write` 上传一份命名策略，随后使用 `vault policy read/list/delete` 和 `vault secrets list/tune/move/disable` 观察这两类对象的生命周期。这个顺序是教学组织方式，涉及的命令均来自官方命令组示例和子命令列表。

![policy 与 secrets 像仓库门禁和仓库货架，共同决定访问路径](/images/ch5-policy-secrets/policy-secrets-control-plane.png)

绘图提示词：手绘风格、真实办公室仓库比喻。画面左侧是一张写着“Policy”的门禁授权清单，列出人员、路径和动作；右侧是一排写着“Secrets Engines”的仓库货架，每个货架入口贴着 `kv/`、`pki/`、`database/` 路径牌。中间有一名管理员把清单交给门卫，门卫只允许学员走向清单中授权的货架。画面应像白板手绘和现场培训插图，不要使用未来感界面，不要使用抽象发光图形。

---

## 2. `vault policy`：从本地文件到服务器中的命名策略

`vault policy write NAME PATH` 会把本地文件中的策略内容上传到 Vault，并以 `NAME` 作为服务器端策略名称；如果 `PATH` 写成 `-`，命令会从标准输入读取策略内容，而不是从本地磁盘读取文件。

`vault policy read NAME` 会打印指定策略的内容和元数据；如果策略不存在，命令会返回错误。该命令支持 `-format` 输出选项，格式可以是 `table`、`json` 或 `yaml`，也可以通过 `VAULT_FORMAT` 环境变量指定默认格式。

`vault policy list` 会列出已经安装在 Vault 服务器上的策略名称，并同样支持 `-format` 输出选项。本教程在排错练习中会先列出策略名称，再读取目标策略内容，以便把“策略是否存在”和“策略内容是否正确”分开观察。

`vault policy fmt PATH` 只处理本地策略文件。它会把指定文件格式化为策略规范要求的样式，并覆盖原文件；因此，在对重要策略文件执行该命令前，应当确认该文件已经纳入版本管理或已经另行备份。

`vault policy delete NAME` 会删除 Vault 服务器中的命名策略，并且所有关联该策略的 token 会立即受到影响。官方文档还特别说明，内置的 `default` 和 `root` 策略不能被删除。

| 子命令 | 管理对象 | 典型用途 | 关键注意事项 |
| --- | --- | --- | --- |
| `vault policy write NAME FILE` | 服务器端命名策略 | 上传或更新策略 | `FILE` 可写成 `-` 从 stdin 读取 |
| `vault policy read NAME` | 服务器端命名策略 | 查看策略内容和元数据 | 不存在会报错，可用 `-format=json` 自动化处理 |
| `vault policy list` | 策略名称列表 | 盘点当前策略 | 支持 `table`、`json`、`yaml` |
| `vault policy fmt FILE` | 本地策略文件 | 统一本地文件格式 | 会覆盖原文件 |
| `vault policy delete NAME` | 服务器端命名策略 | 删除不再使用的策略 | 会立即影响关联该策略的 token，且不能删除 `default` / `root` |

---

## 3. `vault secrets`：机密引擎的启用、盘点、调优、迁移和卸载

`vault secrets enable TYPE` 会在 Vault 中启用一种机密引擎；如果目标路径已经存在机密引擎，命令会返回错误。默认情况下，启用路径等于机密引擎类型；如果需要自定义路径，可以使用 `-path`，并且该路径在所有机密引擎之间必须唯一。

挂载路径是大小写敏感的。官方文档明确指出，启用在 `kv/` 和 `KV/` 的 KV 机密引擎会被视为两个不同实例；这意味着策略路径、应用配置和审计排错都必须严格使用同一套大小写写法。

启用机密引擎时可以附带一部分通用运行配置，例如描述、默认租约 TTL、最大租约 TTL、审计日志中不做 HMAC 的请求或响应字段、请求头透传、允许响应头、托管密钥访问范围、尾部斜杠裁剪以及插件版本等。需要注意，这些是挂载点层面的通用设置，不替代具体机密引擎自己的业务配置。

`vault secrets list` 会列出已经启用的机密引擎，并输出路径、类型、Accessor、TTL 和描述等信息；文档说明，TTL 显示为 `system` 表示该挂载点正在使用系统默认值。

`vault secrets list -detailed` 会显示更详细的挂载信息，例如复制状态、Seal Wrap、外部熵访问、Options、UUID、插件版本、运行版本、运行中插件二进制的 SHA256 以及弃用状态。从 Vault 1.12 开始，内置机密引擎会显示弃用状态，非内置插件的该列显示为 `n/a`。

`vault secrets tune PATH` 会调整指定路径上的机密引擎配置。这里的参数对应的是已经启用的路径，而不是机密引擎类型；例如同一个 `kv` 类型可以挂载在多个路径上，调优时必须写出要调优的那个挂载路径。

`vault secrets tune` 常见选项包括 `-default-lease-ttl`、`-max-lease-ttl`、`-description`、`-listing-visibility`、请求和响应的审计 HMAC 例外、请求头透传、允许响应头、托管密钥访问范围、委派认证 accessor、尾部斜杠裁剪以及 `-plugin-version`。其中 `-max-lease-ttl` 可以高于或低于服务器全局最大 TTL；`-plugin-version` 配置后，新的插件版本要等挂载点重新加载后才会开始运行。

`vault secrets move SOURCE DESTINATION` 会把已有机密引擎移动到新路径。官方文档说明，该命令会撤销来自旧机密引擎的租约，但会保留与该引擎关联的配置；命令会触发 remount 操作，并使用返回的 migration ID 轮询迁移状态，直到进入 `success` 或 `failure` 终态。

跨命名空间移动挂载点时，还需要额外检查目标命名空间是否具备必要策略，以及实体和组是否需要更新。即使本课程实验主要使用单命名空间 dev server，学习者也应知道：官方文档把跨命名空间迁移后的策略、实体和组检查列为迁移后事项。

`vault secrets disable PATH` 会禁用指定路径上的机密引擎；文档强调，参数对应的是已启用路径，而不是机密引擎类型。禁用后，该引擎创建的所有机密都会被撤销，Vault 中属于该引擎的数据也会被移除。

禁用挂载点需要谨慎。官方文档特别提醒，如果某个机密引擎下有大量机密，禁用时的撤销过程可能给系统带来较高负载；如果撤销失败，优先处理底层问题后再禁用，只有在极端恢复场景中才考虑先对挂载前缀执行强制撤销再禁用，因为这可能留下外部系统中的悬空凭据。

| 生命周期阶段 | 命令 | 直接对象 | 主要风险 |
| --- | --- | --- | --- |
| 启用 | `vault secrets enable` | 新挂载路径和引擎类型 | 路径必须唯一且大小写敏感 |
| 盘点 | `vault secrets list` | 已启用挂载点 | 需要区分普通视图和 `-detailed` 视图 |
| 调优 | `vault secrets tune` | 已启用挂载路径 | 参数写路径，不写类型；插件版本变更需重新加载才运行 |
| 迁移 | `vault secrets move` | 源路径和目标路径 | 旧引擎租约会被撤销；迁移后要检查策略、实体和组 |
| 卸载 | `vault secrets disable` | 已启用挂载路径 | 会撤销机密并移除该引擎的数据 |

---

## 4. 将策略与挂载点放入同一条运维流程

本教程建议从盘点开始：先执行 `vault secrets list` 查看已启用的机密引擎，再执行 `vault policy list` 查看已安装的策略名称。这样安排是为了让学习者在执行启用、写入或删除操作前，先观察 Vault 服务器中已有对象。

启用新机密引擎时，可以指定路径、描述和 TTL 等通用挂载参数；随后可以通过 `vault secrets list -detailed` 或 `vault read sys/mounts/<path>/tune` 复核挂载点配置。官方文档同时说明，机密引擎启用后通常还需要进一步配置，具体配置取决于机密引擎类型。

策略文件应先在本地维护，再通过 `vault policy fmt` 统一格式，最后使用 `vault policy write` 上传。对于自动化流水线，`policy write` 支持从 stdin 读取内容，这使得模板渲染后的策略可以直接通过管道交给 Vault，而不一定要落到临时文件。

更新策略后，应通过 `vault policy read` 查看服务器端实际保存的内容，而不是只相信本地文件。删除策略前必须确认影响范围，因为官方文档明确说明，删除策略会立即影响所有关联该策略的 token。

迁移或禁用机密引擎前，应把它视为维护窗口操作：`secrets move` 会撤销旧引擎租约，`secrets disable` 会撤销该引擎创建的机密并移除其 Vault 数据。对于非专家学习者而言，最重要的安全直觉是：`move` 是路径迁移，`disable` 是卸载；二者风险完全不同。

![机密引擎生命周期像设备挂牌、巡检、调参、搬迁和退役](/images/ch5-policy-secrets/secrets-lifecycle-workbench.png)

---

## 5. 常见误区与检查清单

不要把机密引擎类型和挂载路径混为一谈。`secrets enable` 默认把类型名作为路径，但一旦使用 `-path`，后续 `list`、`tune`、`move`、`disable` 都应以实际挂载路径为准。

不要在不了解影响范围时执行 `policy delete`。删除命名策略不是删除本地文件，而是改变 Vault 服务器上的授权对象，并会立即影响所有关联该策略的 token。

不要把 `policy fmt` 当作只读检查命令。它会覆盖指定路径上的本地策略文件，因此更适合在版本管理工作区中使用，或者在执行前保留原始文件副本。

不要把 `secrets disable` 当作普通隐藏操作。它会撤销该引擎创建的机密并移除 Vault 中属于该引擎的数据；如果撤销遇到外部系统问题，应先修复根因，只有在极端恢复场景中才考虑强制撤销挂载前缀。

不要忽略 `secrets list -detailed` 中的运行版本和弃用状态。插件配置版本和实际运行版本可能不同，内置机密引擎还会在弃用状态列中暴露生命周期信息，这些字段对于升级前评估非常有价值。

---

## 6. 互动实验

本节配套实验会在一个 Vault dev server 中综合使用上述命令：先启用、盘点、调优和迁移一个教学用机密引擎，再编写并上传一份策略，随后观察策略变化对实验 token 的影响，最后删除策略并禁用机密引擎。实验流程属于本课程设计，所使用的 `policy` 与 `secrets` 子命令来自官方命令组文档。

- **Step 1**：盘点现有策略和机密引擎，并启用教学用 KV v2 挂载点。
- **Step 2**：调优、迁移和禁用机密引擎，区分 `tune`、`move` 与 `disable` 的影响。
- **Step 3**：使用 `policy fmt`、`policy write`、`policy read` 与 `policy list` 管理策略文件。
- **Step 4**：创建受限 token，验证策略授予的读取能力，并通过更新策略扩大权限。
- **Step 5**：删除策略并禁用机密引擎，观察访问能力和挂载点的终止过程。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-policy-secrets" title="实验：policy 与 secrets 生命周期运维" />
