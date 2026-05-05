---
order: 54
title: 5.4 静态 KV 引擎专属高级指令：get, put, metadata 管理与历史版本 rollback
group: 第 5 章：现代命令行工具与高级管理实战 (CLI)
group_order: 50
---

# 5.4 静态 KV 引擎专属高级指令：get, put, metadata 管理与历史版本 rollback

> **核心结论**：`vault kv` 是面向 Key/Value 机密引擎的专用命令组。与第 5.1 节的 `read`、`write`、`delete`、`list`、`patch` 通用命令相比，`vault kv` 会理解 KV v1 与 KV v2 的差异，自动处理 KV v2 的 `data/`、`metadata/`、`delete/`、`undelete/`、`destroy/` 等内部路径，并提供版本读取、软删除恢复、版本销毁、元数据管理和回滚等专门能力。

本节聚焦静态 KV 机密的 CLI 操作，不要求学员预先具备信息安全背景。可以把 KV 引擎先理解为一个由 Vault 保护的键值档案柜：`put` 放入或改写一份档案，`get` 取出档案内容，`list` 查看某个抽屉下有哪些档案名，`metadata` 查看或调整档案索引卡，`delete`、`undelete`、`destroy` 管理不同强度的删除状态，`rollback` 则把旧版本复制成新的当前版本。

参考文档：

- [vault kv](https://developer.hashicorp.com/vault/docs/commands/kv)
- [vault kv get](https://developer.hashicorp.com/vault/docs/commands/kv/get)
- [vault kv put](https://developer.hashicorp.com/vault/docs/commands/kv/put)
- [vault kv list](https://developer.hashicorp.com/vault/docs/commands/kv/list)
- [vault kv patch](https://developer.hashicorp.com/vault/docs/commands/kv/patch)
- [vault kv metadata](https://developer.hashicorp.com/vault/docs/commands/kv/metadata)
- [vault kv delete](https://developer.hashicorp.com/vault/docs/commands/kv/delete)
- [vault kv undelete](https://developer.hashicorp.com/vault/docs/commands/kv/undelete)
- [vault kv destroy](https://developer.hashicorp.com/vault/docs/commands/kv/destroy)
- [vault kv rollback](https://developer.hashicorp.com/vault/docs/commands/kv/rollback)
- [vault kv enable-versioning](https://developer.hashicorp.com/vault/docs/commands/kv/enable-versioning)

---

## 1. `vault kv` 的路径写法：优先使用 `-mount`

官方文档建议在 KV 命令中使用 `-mount` 标志表示 KV 引擎的挂载路径，例如 `vault kv get -mount=secret creds`。采用这种写法时，`-mount=secret` 表示机密引擎挂载在 `secret/`，后面的 `creds` 才是该引擎内部的机密路径。

旧式写法 `vault kv get secret/creds` 仍可使用，但官方文档明确将其称为已弃用的 path-like syntax，并建议在 KV v2 中避免这种写法。原因在于 KV v2 的真实 API 路径包含额外的 `/data/` 段，例如 `secret/data/creds`；如果命令行看起来像 `secret/creds`，初学者很容易在编写 Policy 或调用 HTTP API 时漏掉 `data/`。

命令选项的位置也需要固定：某个子命令的选项放在子命令之后、路径参数之前。示例中应写成 `vault kv get -mount=secret -version=2 creds`，而不是把 `-version=2` 放到路径后面。

如果执行 `vault kv get -mount=secret creds` 时出现 `flag provided but not defined: -mount`，官方文档指出这通常表示 Vault 版本早于引入 `-mount` 语法的版本，需要升级到至少 Vault 1.11，或查阅旧版本文档采用当时支持的写法。

![KV v2 的挂载路径与真实 API 路径像档案柜抽屉和内部夹层](/images/ch5-kv-commands/kv-mount-data-metadata-cabinet.png)

---

## 2. `enable-versioning`：把已有 KV v1 挂载点切换为版本化 KV

`vault kv enable-versioning <path>` 用于对一个已经存在的非版本化 KV 引擎启用版本控制，也就是把 KV v1 挂载点调整为版本化的 KV 存储。官方示例使用 `vault kv enable-versioning secret`，成功后输出 `Success! Tuned the secrets engine at: secret/`。

这个命令的用途不是新建 KV 引擎，而是调整已有的非版本化 KV 挂载点。换言之，本节只把 `enable-versioning` 视为已有 KV v1 挂载点的转换命令，而不把它当作新建引擎命令。

`enable-versioning` 的官方页面没有列出额外的 command options；它仍支持 `-format` 输出选项，可输出 `table`、`json` 或 `yaml`，也可通过 `VAULT_FORMAT` 环境变量指定默认格式。

---

## 3. `put`、`get`、`list`：静态机密的基础读写与目录观察

`vault kv put` 会把数据写入指定 KV 路径。对于 KV v2，每次写入都会在该路径下创建一个新的版本；对于 KV v1，则是在指定位置存储给定机密。无论使用哪个版本，如果路径原本不存在，调用方令牌需要具备 `create` capability；如果路径已经存在，则需要具备 `update` capability。

最常见的输入形式是 `key=value`。例如 `vault kv put -mount=secret app/db username=app password=initial` 会在 `secret/` 挂载下写入 `app/db` 这条机密，并保存两个字段。`put` 还可以用 `@` 从磁盘文件读取数据，也可以用 `-` 从标准输入读取某个字段的值。

在 KV v2 中，`put` 是一次完整写入。即使只想改变一个字段，也必须意识到本次写入会形成新版本；如果只希望合并少量字段，更适合使用 `vault kv patch`，这一点会在第 5 节展开。

`vault kv get` 用于读取给定 key 的值。如果 key 不存在，会返回错误；如果 key 存在但没有数据，则不返回数据。对于 KV v2，默认读取最新版本，也可以用 `-version=<number>` 读取指定版本。

KV v2 的 `get` 输出包含 Metadata 和 Data 两部分，Metadata 中有版本号、创建时间、删除时间和是否已销毁等信息；KV v1 没有版本化信息，因此官方示例显示 KV v1 输出没有 Metadata 块。

如果只需要某个字段，可以使用 `-field=<name>`，例如 `vault kv get -mount=secret -field=password app/db`。官方文档说明 `-field` 会优先于其他格式化指令，只打印指定字段，并且末尾不附加换行，适合管道传递给其他进程。

`vault kv list` 用于列出某个路径下的 key 名称。官方文档提醒，文件夹会以 `/` 结尾，输入必须是文件夹；对一个文件执行 list 不会返回值。它只列出名称，不读取机密值。

`list` 不会按照 Policy 对 key 名称进行过滤，因此不要把敏感信息写进 key 名称。一个不合适的路径名可能在列表输出中暴露业务含义，即使列表命令不会返回真正的机密值。

---

## 4. KV v2 的删除不是一种动作，而是三种状态管理

KV v2 把删除拆成三类不同强度的动作。`vault kv delete` 会删除给定路径的数据；如果使用 KV v2，版本化数据不会被完全移除，而是被标记为 deleted。此时 `get` 可能仍显示带 `deletion_time` 的 Metadata，但不会返回该版本的 Data 内容。

`vault kv delete -mount=secret creds` 删除的是最新版本；`vault kv delete -mount=secret -versions=11 creds` 删除的是指定版本。官方文档注明，`-versions` 选项只适用于 KV v2，并且被删除的版本化数据不会物理删除，只是不再通过普通 `get` 请求返回 Data 内容。

`vault kv undelete` 用于撤销指定版本的软删除状态，使该版本的数据重新可以被 `get` 返回；它不能恢复已经被 `destroy` 永久移除的数据。该命令只适用于 KV v2，不适用于 KV v1。

`vault kv destroy` 用于永久移除一个或多个指定版本的数据。官方文档说明，被 destroy 的版本数据会被永久删除；如果路径不存在，则不会执行任何动作。这个命令只适用于 KV v2。

`vault kv metadata delete` 是更彻底的清理动作，它会删除某个 key 的所有版本和元数据。与只销毁某些版本的 `destroy` 不同，metadata delete 会把这条 key 的版本历史和 key 级配置一起移除。

| 命令 | 删除范围 | 是否可恢复 | 适用场景 |
| --- | --- | --- | --- |
| `vault kv delete` | 最新版本或指定版本的删除标记 | 可用 `undelete` 恢复 | 误操作保护、临时隐藏版本 |
| `vault kv undelete` | 撤销指定版本删除标记 | 恢复动作本身 | 误删后的恢复 |
| `vault kv destroy` | 指定版本的数据内容 | 不可恢复 | 确认某个版本不应再被读取 |
| `vault kv metadata delete` | 所有版本和 metadata | 不可恢复 | 彻底下线某条 key |

![KV v2 删除三态像档案上的便签、碎纸和注销登记本](/images/ch5-kv-commands/kv-delete-states-office-analogy.png)

---

## 5. `metadata`、CAS 与 `patch`：控制版本规则并降低误覆盖风险

`vault kv metadata` 是 KV v2 专属命令组，用于与版本化机密的 metadata 端点交互，包含 `delete`、`get`、`put` 三个子命令。它不适用于 KV v1。

`vault kv metadata get` 会读取某个 key 的 metadata。如果 key 不存在，会返回错误。输出中可以看到 `current_version`、`max_versions`、`cas_required`、`delete_version_after`，以及每个版本的创建时间、删除时间和 destroyed 状态。

`vault kv metadata put` 可以创建一个没有数据的空 key，也可以更新某个 key 的配置。常用参数包括 `-max-versions`、`-cas-required`、`-delete-version-after` 和可重复指定的 `-custom-metadata`。

`-max-versions` 表示每个 key 保留多少个版本；如果不设置，则使用后端的全局配置。官方文档说明，当 key 的版本数量超过允许保留的数量时，最旧版本会被永久删除。

`-delete-version-after` 用持续时间表示新版本写入后多久设置删除时间；如果 key 级别不设置，则使用后端配置。如果 key 级设置大于后端配置，实际会使用后端的 `delete_version_after`。官方文档还提醒，对该设置的修改只会影响新版本。

CAS 是 Check-And-Set 的缩写，可以理解为“写入前先确认当前版本号”。`vault kv put -cas=<number>` 会要求本次写入只在版本号符合预期时成功；如果 `-cas=0`，则只有 key 不存在时才允许写入。官方文档还说明，软删除不会移除底层版本数据，因此要向软删除的 key 写入数据时，CAS 参数必须匹配该 key 的当前版本。

如果在 key 或引擎配置上启用了 `cas_required`，写入请求必须带 CAS 参数。`metadata put -cas-required` 可以对某个 key 启用这一要求；在多人或多进程可能同时写入同一路径时，这种机制可用于降低误覆盖风险。

`vault kv patch` 是 KV v2 专属命令，用于把给定数据合并到已有数据中，而不是像 `put` 那样替换为一份完整的新数据。官方示例说明，如果只想给已有 `creds` 增加 `ttl=48h`，`patch` 可以直接写入新增字段；若用 `put` 达到同样结果，则必须同时提供已有数据和新增数据。

`patch` 支持两种方法：默认 `-method=patch` 使用 HTTP `PATCH` 请求执行局部更新；`-method=rw` 会先读取机密数据，在内存中合并，再把更新后的数据写回。`-cas` 只适用于默认的 `patch` 方法；对于 `rw` 方法，CAS 值会通过读取当前版本派生出来。

---

## 6. `rollback`：把历史版本复制成新的当前版本

`vault kv rollback` 用于把某个旧版本恢复为当前版本。官方文档特别说明，rollback 的结果不是删除较新的版本，也不是把版本号倒退，而是把指定旧版本的值写成一个新版本。

如果当前版本是 5，而执行 `vault kv rollback -mount=secret -version=2 creds`，版本 2 的数据会成为版本 6。这样做的好处是版本号继续向前推进，历史版本记录不会因为回滚而倒退或被抹掉。

`rollback` 只适用于 KV v2。它需要 `-version=<number>` 指定要恢复的历史版本，也支持 `-mount` 表示 KV 挂载路径；输出格式可以通过 `-format` 设置为 `table`、`json` 或 `yaml`。

---

## 7. 命令选择速查表

学习 KV 命令时，可以先按目标选择命令，再考虑是否涉及版本。只想写入完整机密时使用 `put`，只改少量字段时优先考虑 `patch`，查看内容用 `get`，查看目录用 `list`，查看版本历史和 key 级配置用 `metadata get`，误删恢复用 `undelete`，永久清理某个版本用 `destroy`，需要把旧内容恢复为新的当前版本时使用 `rollback`。

| 目标 | 推荐命令 | 关键提醒 |
| --- | --- | --- |
| 写入完整数据 | `vault kv put -mount=secret path key=value` | KV v2 每次写入产生新版本 |
| 读取最新版本 | `vault kv get -mount=secret path` | KV v2 输出含 Metadata 与 Data |
| 读取指定版本 | `vault kv get -mount=secret -version=2 path` | 只能读取未被软删除且未被 destroy 的版本 |
| 列出目录 | `vault kv list -mount=secret folder/` | 不要把敏感信息放进 key 名称 |
| 局部更新 | `vault kv patch -mount=secret path key=value` | KV v2 专属，合并已有数据 |
| 查看版本历史 | `vault kv metadata get -mount=secret path` | 查看 `current_version` 与每个版本状态 |
| 设置 key 级规则 | `vault kv metadata put -mount=secret ... path` | 可设置 CAS、保留版本数、自动删除时间 |
| 软删除 | `vault kv delete -mount=secret path` | KV v2 可恢复 |
| 撤销软删除 | `vault kv undelete -mount=secret -versions=3 path` | KV v2 专属 |
| 永久销毁版本 | `vault kv destroy -mount=secret -versions=3 path` | 不可恢复 |
| 删除全部版本和元数据 | `vault kv metadata delete -mount=secret path` | 不可恢复 |
| 恢复历史内容 | `vault kv rollback -mount=secret -version=2 path` | 旧内容会成为新版本 |

---

## 8. 互动实验

本节配套实验覆盖官方 KV 命令文档中的主要 CLI 能力：`-mount` 写法、`enable-versioning`、基础读写、字段读取、目录列表、metadata 管理、CAS 参数、局部 patch、删除三态以及 rollback。

- **Step 1**：使用 `-mount` 写法，并把一个 KV v1 挂载点切换为版本化 KV
- **Step 2**：使用 `put`、`get`、`list` 完成静态机密的基础操作
- **Step 3**：通过 `metadata put`、CAS 与 `patch` 观察防误覆盖机制
- **Step 4**：体验 `delete`、`undelete`、`destroy`、`metadata delete` 的差异
- **Step 5**：使用 `rollback` 把历史版本复制为新的当前版本

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch5-kv-commands" title="实验：KV 专用命令 get / put / metadata / rollback" />