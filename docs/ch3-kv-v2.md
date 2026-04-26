---
order: 32
title: 3.2 Key/Value (KV v2) 引擎：版本控制的现代静态机密存储
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.2 Key/Value (KV v2) 引擎：版本控制的现代静态机密存储

> **核心结论**：KV v2 是 Vault 中最常用的"纯存储类"机密引擎。在 v1 的
> 基础上，v2 增加了 **版本历史**、**软删除 / 硬删除 / 元数据销毁三态**、
> **CAS（Check-And-Set）写并发控制**、以及 **`max_versions` /
> `delete_version_after` 自动回收**。所有这些能力靠的是同一个机制：
> **路径被拆成 `data/` 和 `metadata/` 两条平行命名空间**——这也是初学
> KV v2 时最容易踩到的所有"奇怪"行为的根源。

参考：
- [KV — Vault Secrets Engines Docs](https://developer.hashicorp.com/vault/docs/secrets/kv)
- [KV v2 Concept](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)
- [KV v2 API](https://developer.hashicorp.com/vault/api-docs/secret/kv/kv-v2)
- [vault kv CLI](https://developer.hashicorp.com/vault/docs/commands/kv)

---

## 1. 为什么需要 KV v2

KV v1 把每条 key 的值原地覆盖；一旦 `vault kv put secret/db password=new`
执行下去，旧密码就**永远找不回来**了。这在生产环境是非常危险的：

- 凭据被错误地覆盖（脚本 bug、人为失误）后无法回滚
- 想要做"灰度回退"——还原到上一版本——根本不可能
- 审计需要回答"上周三下午三点这个 key 是什么值"——v1 答不出来

KV v2 给每次写入都保留一个**带版本号的快照**，并允许定向读、删除、销毁
任何一个历史版本。代价是 v2 在路径与 API 形态上比 v1 复杂——理解这套
路径双层结构是用好 KV v2 的前提。

> **二者不能互相 in-place 升级**：v1 与 v2 是两套不同的 API 形态，
> `vault secrets move` 只改路由表里的挂载路径、**不会**改引擎类型或
> options（参见 [3.1 §3.4](/ch3-secrets-engines#34-move-原子重命名挂载路径)
> 与 [5.7 Mount Migration](/ch5-mount-migration) 中的"不能跨类型"限制）。
> 要从 v1 切到 v2，唯一的办法是：在新路径起一个 v2 实例，写脚本把 v1
> 的数据逐条读出来再写进 v2，确认后再 `disable` 掉旧的 v1（注意
> `disable` 是销毁式的，迁移完成前别动它）。

---

## 2. 路径双层结构：`data/` 与 `metadata/`

KV v2 在你启用引擎那一刻，就在这条挂载路径下**自动展开一组并列的子路径**，
每一条对应一类操作语义：

```
mount/                       ← 你 enable 时给的路径，比如 secret/
├── data/<path>              ← 实际的机密内容（带版本号）
├── metadata/<path>          ← 该 key 的元数据（版本列表、自定义 metadata、TTL 等）
├── delete/<path>            ← 软删除指定版本（保留可 undelete）
├── undelete/<path>          ← 撤销软删除
├── destroy/<path>           ← 硬删除指定版本（不可恢复，但 metadata 还在）
├── subkeys/<path>           ← 只看 key 名结构，不看值（v1.13+）
└── config                   ← 引擎全局配置（max_versions / cas_required / ...）
```

注意这里 7 条子路径**不是 7 个独立的引擎实例**——它们都属于同一个
KV v2 挂载，共享同一份底层数据；只是 v2 把"读数据 / 改数据 / 看元数据 /
软删 / 撤销软删 / 硬删 / 调全局配置"切成了**按动作分开的 HTTP 端点**，
方便 Policy 按动作精细授权（详见 §7）。

其中 `data/` 和 `metadata/` 是最核心的两条——**业务数据走 `data/`、
版本历史与自定义 metadata 走 `metadata/`**，剩下几条本质上都是"对某个
版本做某个动作"的写入入口。

CLI 的 `vault kv put / get / list / delete` 是**便利封装**——它会自动
帮你拼上 `data/` 或 `metadata/` 等前缀。但所有 Policy、所有直接走
HTTP API 的应用、以及所有 `vault read / write` 调用，都必须**显式**写
出完整路径：

| CLI 形式 | 实际作用的 HTTP 路径 |
| --- | --- |
| `vault kv put   secret/foo a=1` | `POST secret/data/foo` |
| `vault kv get   secret/foo`     | `GET  secret/data/foo` |
| `vault kv list  secret/`        | `LIST secret/metadata/` |
| `vault kv delete secret/foo`    | `DELETE secret/data/foo`（软删除最新版） |
| `vault kv destroy secret/foo`   | `POST secret/destroy/foo` |
| `vault kv metadata get secret/foo` | `GET  secret/metadata/foo` |

> **第一个常见踩坑**：在 Policy 里写 `path "secret/foo" { ... }` 是
> 对 v1 才生效的；v2 上必须写 `path "secret/data/foo" { ... }`，否则
> 应用永远是 403。详见 §7。

---

## 3. 基本 CRUD

### 3.1 启用引擎

```bash
vault secrets enable -path=kv kv-v2
# 等价：vault secrets enable -version=2 -path=kv kv
```

注意 `vault secrets list` 看到的 Type 列是 `kv`、Options 列里写
`version:2`——**没有 `kv-v2` 这种类型名**。这一点和 3.1 §3.1 里强调
过的"Type 名 ≠ 别名"一致。

### 3.2 写入

```bash
vault kv put kv/app/db username=root password=s3cret
```

输出会带版本号、创建时间、自定义元数据等信息：

```
====== Secret Path ======
kv/data/app/db

======= Metadata =======
Key                Value
---                -----
created_time       2026-04-26T10:00:00.123Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            1
```

### 3.3 读取

```bash
vault kv get kv/app/db                      # 默认读最新版本
vault kv get -version=1 kv/app/db           # 指定版本
vault kv get -format=json kv/app/db | jq .data  # 拿干净的数据 + 元数据
```

`-format=json` 输出的结构：

```json
{
  "data": {
    "data": { "username": "root", "password": "s3cret" },
    "metadata": { "version": 2, "destroyed": false, ... }
  }
}
```

注意嵌套了两层 `data`——外层是 v2 的 envelope，内层才是你写进去的
key-value。`jq .data.data` 拿真实数据，`jq .data.metadata` 拿元数据。

### 3.4 列表

```bash
vault kv list kv/app/                       # 列出 app/ 下的 key
```

KV v2 的 `list` 走的是 `metadata/` 路径，所以**软删除 / 硬删除的 key
仍然会出现在列表里**（除非走 `metadata delete` 把元数据也清掉，见 §5）。

### 3.5 局部更新：`patch`

```bash
vault kv patch kv/app/db password=newer
```

`put` 是**全量覆盖**——你必须把所有字段都写一遍，否则没列出的 key 会
丢。`patch` 是**字段级合并**——只改你提到的字段，其他保留。底层走的
是 HTTP `PATCH` 方法，需要 Vault 1.9+ 的服务端支持。

> 历史踩坑：v1 的 `patch` 是在客户端先 `read` 再 `put`，并发场景下有
> 丢失更新的风险。v2 的 `patch` 在服务端用 CAS 完成，安全得多。

---

## 4. 版本控制三件套

### 4.1 多次写入产生新版本

```bash
vault kv put kv/app/db password=v1
vault kv put kv/app/db password=v2
vault kv put kv/app/db password=v3
```

每次 `put` 把 `version` 加一，旧版本不删除。

### 4.2 查看完整版本元数据

```bash
vault kv metadata get kv/app/db
```

看到的是一张版本表：

```
Key                     Value
---                     -----
cas_required            false
created_time            ...
current_version         3
delete_version_after    0s
max_versions            0
oldest_version          0
updated_time            ...

====== Version 1 ======
Key              Value
---              -----
created_time     ...
deletion_time    n/a
destroyed        false
...
```

### 4.3 定向读取历史版本

```bash
vault kv get -version=1 kv/app/db
vault kv get -version=2 kv/app/db
```

任意一个未被 `destroy` 的版本都能定向读出来——这是 v2 相对 v1 最大的
价值。

---

## 5. 删除的三态：软删除 / 硬删除 / 元数据销毁

KV v2 把"删除"切成三个独立操作，对应三种不同的可恢复性：

| 操作 | 数据状态 | 元数据 | 可否恢复 | 何时使用 |
| --- | --- | --- | --- | --- |
| `vault kv delete` | 标记 `deletion_time`，数据仍在 | 保留 | ✅ `vault kv undelete` | 误删保护 |
| `vault kv destroy -versions=N` | 物理擦除该版本数据 | 保留（标 `destroyed=true`） | ❌ | 凭据泄露需要确认销毁 |
| `vault kv metadata delete` | 物理擦除所有版本 + 元数据 | **清空** | ❌ | 彻底下线某条 key |

### 5.1 软删除与撤销

```bash
vault kv delete kv/app/db                   # 软删除最新版
vault kv get   kv/app/db                    # 报 deletion_time 已设置
vault kv undelete -versions=3 kv/app/db     # 还原 v3
```

> 软删除可指定版本：`vault kv delete -versions=2,3 kv/app/db`。

### 5.2 硬删除（不可恢复）

```bash
vault kv destroy -versions=1 kv/app/db
vault kv get -version=1 kv/app/db          # invalid version
```

`destroyed=true` 之后该版本的数据块被擦除，任何方式都拿不回来——但
metadata 中仍记录"曾经存在过 v1，已被销毁"。

### 5.3 元数据销毁（最彻底）

```bash
vault kv metadata delete kv/app/db
vault kv list kv/app/                       # app/db 不再出现
```

整条 key 从 `metadata/` 中消失，所有版本的数据被擦除——相当于这个
key 从未存在过。**审计日志当然还会保留这次操作的记录**。

---

## 6. 自动回收与并发控制

### 6.1 全局配置

```bash
vault read kv/config
vault write kv/config max_versions=5 cas_required=false delete_version_after=720h
```

| 字段 | 含义 |
| --- | --- |
| `max_versions` | 每条 key 最多保留几个历史版本，超出的自动 destroy（按时间最早） |
| `cas_required` | 全局开启 CAS 写：每次 `put` 必须带上 `cas=N`（期望的当前版本号） |
| `delete_version_after` | 每个版本写入后多久自动软删除（默认 0 = 不自动） |

### 6.2 单条 key 覆盖全局配置

```bash
vault write kv/metadata/app/db max_versions=3
```

写到 `metadata/<path>` 的字段会覆盖 `config` 上的全局值——同时还可以
写入 `custom_metadata`：

```bash
vault kv metadata put -custom-metadata=owner=team-a kv/app/db
```

### 6.3 CAS 写

CAS（Check-And-Set）防止两个客户端同时 `put` 互相覆盖：

```bash
vault kv put -cas=2 kv/app/db password=safe
```

意思是"我看到的当前版本是 2，请在 2 的基础上写出 3"。如果实际 current
是 5，写入失败、不会产生 v6 也不会覆盖 v5——客户端自己决定怎么重试。

---

## 7. Policy 路径：每个动作单独授权

KV v2 的强大之处也意味着 Policy 必须按动作分开授权：

```hcl
# 应用：只读最新数据
path "kv/data/app/*" {
  capabilities = ["read"]
}
# 应用：列出 key
path "kv/metadata/app/*" {
  capabilities = ["list", "read"]
}

# 运维：能写、能 patch、能软删除，但不能销毁
path "kv/data/app/*"     { capabilities = ["create", "update", "patch"] }
path "kv/delete/app/*"   { capabilities = ["update"] }
path "kv/undelete/app/*" { capabilities = ["update"] }

# 安全管理员：被授权的销毁能力
path "kv/destroy/app/*"          { capabilities = ["update"] }
path "kv/metadata/app/*"         { capabilities = ["delete"] }   # 元数据销毁
```

| 想做的事 | 需要的路径 + capability |
| --- | --- |
| `vault kv put / patch` | `data/*` 上 `create` / `update` / `patch` |
| `vault kv get` | `data/*` 上 `read` |
| `vault kv list` | `metadata/*` 上 `list` |
| `vault kv metadata get` | `metadata/*` 上 `read` |
| `vault kv delete`（软删除） | `delete/*` 上 `update`（或对最新版用 `data/*` 的 `delete`） |
| `vault kv undelete` | `undelete/*` 上 `update` |
| `vault kv destroy` | `destroy/*` 上 `update` |
| `vault kv metadata delete` | `metadata/*` 上 `delete` |

> **第二个常见踩坑**：很多教程里写 `path "secret/foo" { capabilities
> = ["read"] }`——这是 KV v1 的写法。在 v2 上它**完全不会授权
> 任何东西**，因为 v2 的实际路径是 `secret/data/foo`、`secret/metadata/foo`
> 等。Policy 路径错配会让你的应用百思不得其解地拿到 403。

---

## 8. 与 5.7 Mount Migration 的衔接

KV v2 既然是把数据存进 Vault 的最常见入口，它也是**最常被 `vault
secrets move` 搬动的引擎**——尤其是从 dev 环境的默认 `secret/` 搬到
生产规范命名 `kv-prod/` 时。两个细节必须复习一下：

- 搬完之后 Accessor / UUID / 版本历史 / `max_versions` 都不变
- Policy 里写死的 `secret/data/...` **不会**变成 `kv-prod/data/...`，
  搬完得手动同步——这正是 [5.7 Mount Migration](/ch5-mount-migration)
  里反复演示的"Policy 断裂 → 403"故事

---

## 9. 互动实验

本节配套了一个完整的 Killercoda 实验：

- **Step 1**：启用 KV v2，写入第一条数据，亲眼看 `data/` 与 `metadata/`
  双层路径在 HTTP 层是怎么暴露的
- **Step 2**：连续多次写入产生版本历史，演示 `get -version`、`patch`
  局部更新与 CAS 写的拒绝行为
- **Step 3**：跑一遍删除三态——软删 → undelete → destroy → metadata
  delete，亲手观察每一态下数据与元数据的变化
- **Step 4**：写两条 Policy，演示"路径前缀对了但少了 `data/` 段"会
  导致 403，再用正确路径修复——把 §7 的踩坑变成肌肉记忆

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-kv-v2" title="实验：KV v2 版本控制、软删硬删与 Policy 路径" />
