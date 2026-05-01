---
order: 314
title: 3.14 PostgreSQL 数据库机密引擎：动态账号、静态轮转与连接接管
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.14 PostgreSQL 数据库机密引擎：动态账号、静态轮转与连接接管

> **核心结论**：PostgreSQL 机密引擎是 Vault 内置 Database 机密引擎的众多插件之一，由
> `postgresql-database-plugin` 实现。
> 它把对一个 PostgreSQL 实例的"建账号 / 改密码 / 删账号"能力封装成 Vault 的标准
> Database engine 路径：`database/config/<name>` 写连接，`database/roles/<name>` 写
> Dynamic Role，`database/static-roles/<name>` 写 Static Role。
> 应用拿一个 Vault Token 即可 `vault read database/creds/<role>` 即时获得短寿命的
> PostgreSQL `username` / `password` 与 Lease。
> 这一节把「插件能力 → 配置形状 → 三种使用模式 → SSL/IAM 进阶 → 常见坑」一次串清，
> 并明确企业版与开源版的能力分界。

参考：
- [PostgreSQL database secrets engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
- [Database secrets engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/databases)（上层框架，本插件遵循其通用约定）
- [PostgreSQL database plugin API](https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql)
- 同模型对照：[3.10 LDAP 机密引擎](/ch3-ldap)（Static / Dynamic 与本节如出一辙，只是目标系统不同）
- 概念基础：[2.3 Lease](/ch2-lease)、[3.1 Secrets Engines](/ch3-secrets-engines)

![PostgreSQL Database Secrets Engine architecture](/images/ch3-postgres/postgres-database-engine-architecture.png)

---

## 1. 一句话定位：是 Database 引擎下的 PostgreSQL 插件，不是独立路径

启用 Vault 的"数据库"机密能力时，**只挂载一次** `database/` 总路径，再在它下面为不同
DB 实例各写一份 `database/config/<name>`：

```bash
$ vault secrets enable database
Success! Enabled the database secrets engine at: database/
```

> 默认按引擎名挂在 `database/`；要换路径就给 `-path` 参数。

`postgresql-database-plugin` 是 Vault 内建的 PostgreSQL 适配器，底层借助 [pgx](https://pkg.go.dev/github.com/jackc/pgx/stdlib)
完成所有 SQL 与连接操作；连接串里包括 SSL 在内的所有选项写法都遵循 pgx / PostgreSQL
官方约定。

---

## 2. 插件能力速览（Capabilities）

官方在 Capabilities 一节用一张表给出该插件支持的能力：

| 插件 | Root Credential Rotation | Dynamic Roles | Static Roles | Username Customization | Credential Types |
| --- | --- | --- | --- | --- | --- |
| `postgresql-database-plugin` | Yes | Yes | Yes | Yes (1.7+) | password, gcp_iam |

四个布尔列与一列凭据类型对应到本节后续四块内容：

- **Root Credential Rotation = Yes** → §3 中 `vault write -force database/rotate-root/<name>` 可用
- **Dynamic Roles = Yes** → §4 用 `database/roles/<name>` + `database/creds/<name>` 走动态发号
- **Static Roles = Yes** → §5 用 `database/static-roles/<name>` + `database/static-creds/<name>` 走轮转
- **Credential Types: password, gcp_iam** → §7 GCP CloudSQL IAM 一节使用 `auth_type=gcp_iam`

> 上层 Database 文档另有总述：自 Vault 1.6 起，Dynamic Roles 与 Static Roles 已成为通用能力；
> 除 MongoDB Atlas 外，数据库插件通常支持轮转 root 用户凭据。不过跨数据库能力仍应以同页当前能力表逐行确认为准；
> 就 PostgreSQL 而言，表中明确列为 Root Credential Rotation / Dynamic Roles / Static Roles 均为 Yes。

---

## 3. 配置（Setup）：root 连接 + 角色

### 3.1 写入连接配置

```bash
$ vault write database/config/my-postgresql-database \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="postgresql://{{username}}:{{password}}@localhost:5432/database-name" \
    username="vaultuser" \
    password="vaultpass" \
    password_authentication="scram-sha-256"
```

字段含义（每一行都来自官方示例字段）：

| 字段 | 含义 | 出处 |
| --- | --- | --- |
| `plugin_name` | 固定为 `postgresql-database-plugin` | 官方 Setup §2 示例 |
| `allowed_roles` | 列出可绑到本连接的 role 名（支持通配；逗号分隔） | 官方 Setup §2 示例与上层 Database 文档 setup 段一致字段 |
| `connection_url` | DSN 形式的连接串，`{{username}}` / `{{password}}` 占位符由 Vault 在每次连接前注入 | 官方 Setup §2 示例 |
| `username` / `password` | Vault 自身用来连 PG 的"root"账号；Vault 用它去执行 CREATE / ALTER / DROP ROLE 等管理操作 | 官方 Setup §2 示例；上层 Database 文档 Setup 段「Vault will use the user specified here to create/update/revoke database credentials. That user must have the appropriate permissions to perform actions upon other database users (create, update credentials, delete, etc.).」 |
| `password_authentication="scram-sha-256"` | 让 Vault 先按 SCRAM-SHA-256 生成哈希，再由 PostgreSQL 原样存储；Vault API 默认值是 `password`，`scram-sha-256` 需要 PostgreSQL 10+ | 官方 Setup §2 示例最后一行；PostgreSQL database plugin API 中 `password_authentication` 字段说明 |

> **强烈建议为 Vault 单独建一个数据库账号**（不要把现有业务超级用户拿来用）——
> Vault 会用它"代为操纵其它数据库账号"，因此需要 CREATE / ALTER / DROP ROLE 等管理权限。

### 3.2 立刻轮一次 root（强烈建议）

写完 `database/config/<name>` 后，**官方建议**立刻执行：

```bash
$ vault write -force database/rotate-root/my-postgresql-database
```

执行之后，**第 3.1 步里那行 `password="vaultpass"` 立即作废**——新密码只存在 Vault 内部，
任何人（包括管理员）都无法再读出来。

> **绝对不要**让 Static Role 和 root 凭据指向**同一个**数据库账号——Vault 在轮密码时
> 不区分"普通账号"与"root 账号"，Static Role 一旦轮了 root 账号的密码，`database/config/<name>`
> 里登记的连接立刻失效，导致此后所有 dynamic / static 都用不了。

### 3.3 写一个 Dynamic Role

```bash
$ vault write database/roles/my-role \
    db_name="my-postgresql-database" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"
Success! Data written to: database/roles/my-role
```

要点：

- `db_name` 必须等于 §3.1 里那个 `database/config/<name>` 末段名（这里是 `my-postgresql-database`）
- `creation_statements` 是一段或多段 SQL 模板，由 PostgreSQL 在每次申领时执行；Vault 在执行前把 `{{name}}` / `{{password}}` 占位符替换为本次随机生成的用户名/密码，`{{expiration}}` 可选
- `default_ttl` / `max_ttl` 决定每条 Lease 的初始 TTL 与允许续到的最大 TTL

---

## 4. Usage：读 `database/creds/<role>` 即得动态凭据

```bash
$ vault read database/creds/my-role
Key                Value
---                -----
lease_id           database/creds/my-role/2f6a614c-4aa2-7b19-24b9-ad944a8d4de6
lease_duration     1h
lease_renewable    true
password           SsnoaA-8Tv4t34f41baD
username           v-vaultuse-my-role-x
```

每次读都触发一条 SQL 在 PostgreSQL 内部 **现场创建一个新账号**，把生成的
`username` / `password` 与 `lease_id` 一并交给客户端。
Lease 过期或 `vault lease revoke <lease_id>` 时，Vault 调用预设的 revocation
SQL 把这个账号从 PostgreSQL 上清掉。

> 与 [3.10 LDAP](/ch3-ldap) 的 Dynamic Role 完全同模型——只是清理对象从 LDAP entry 变成 PG `ROLE`。
> 与 [3.3 AWS](/ch3-aws) 的 IAM User 凭据同理，唯一的差异在于"被代管的外部系统"不同。

---

## 5. Static Roles：长寿命账号、密码周期轮转

> **形状**：Static Role 与 PostgreSQL 数据库里一个**已存在**的用户做 1:1 映射，
> Vault 负责按你设的周期（或 cron 表达式）替它轮密码。

### 5.1 默认行为：onboarding 时**立即轮一次密码**

通过 Create static role API 把一个 PG 用户纳入 Vault 管理时，**默认会立刻轮转一次**该用户在数据库里的密码。

这意味着**应用在 onboarding 之前**还在用的旧密码会瞬间失效——如果应用没准备好从
Vault 读密码，下一次连接就会被拒。

### 5.2 平滑接管：`skip_import_rotation` 与 `password`

为了缓解上述切换难题，官方上层文档给出两条可同时使用的旋钮；但当前 API 页把
`skip_static_role_import_rotation`、`skip_import_rotation` 以及 onboarding 时写入静态账号既有
`password` 标为 Enterprise 能力，使用前应按实际 Vault 版本与许可确认：

1. **关闭 onboarding 立刻轮转**——可在 connection 级用 `skip_static_role_import_rotation` 关，或在每个 role 上用 `skip_import_rotation` 关。
2. **在 onboarding 时显式传入"既有密码"**——通过 static role 的 `password` 字段把现有密码告诉 Vault，Vault 接管后第一次轮转之前仍能把这个已知密码交给应用，便于多客户端逐步切换。

### 5.3 轮转节奏：周期 vs Cron

两种方式 **二选一、不可同设**：

```bash
# 方式 A：固定周期
$ vault write database/static-roles/my-role \
    db_name="my-postgresql-database" \
    username="staticuser" \
    rotation_period="1h"

# 方式 B：cron 表达式
$ vault write database/static-roles/my-role \
    db_name=my-database \
    username="vault" \
    rotation_schedule="0 0 * * SAT"
```

> API 页还说明 `rotation_schedule` 使用五字段 cron，并由 Vault 按 UTC 解释。

读当前密码：

```bash
$ vault read database/static-creds/my-role
Key                    Value
---                    -----
last_vault_rotation    2024-09-11T14:15:13.764783-07:00
password               XZY42BVc-UO5bMsbgxrW
rotation_period        1h
ttl                    59m55s
username               staticuser
```

> 可选地，`rotation_schedule` 可叠加 `rotation_window`：定义一个时间窗，在窗内若因故障未能轮成，
> 直到下一个排期才会再尝试。

---

## 6. Rootless Configuration：每个 Static Role 自带一条独立连接 (Enterprise)

> **企业版限定**：本节描述的功能 **必须 Vault Enterprise**，开源版不可用。

形状：

```bash
$ vault write database/config/my-postgresql-database \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="postgresql://{{username}}:{{password}}@localhost:5432/database-name" \
    self_managed=true

$ vault write database/static-roles/my-role \
  db_name="my-postgresql-database" \
  username="staticuser" \
  self_managed_password="password" \
  rotation_period="1h"
```

> 当前 PostgreSQL 教程页仍用 `self_managed_password`；Database API 页已把该参数标为
> deprecated，并说明新写法优先使用 static role 的 `password` 字段。

与默认（root 模型）相比的两点关键差异：

1. `database/config/<name>` 不再填 `username` / `password`；改用 `self_managed=true` 表明"这条连接没有特权 root 账号"。
2. **每个 static role 各自打开一条独立 DB 连接**，官方示例用 `self_managed_password` 携带该账号自己的当前密码登入；后续的轮转也只在这条专属连接上进行。

副作用与硬约束：

- **不支持 Dynamic Roles**
- 强烈建议被纳入的账号只持最小权限——每个 static role 都会开一条新连接，权限越大风险越高
- **带外（out-of-band）改密会让 Vault 与数据库失同步**——必须人工去 PG 把账号密码改回与 Vault 当前一致才能继续轮转

---

## 7. 进阶认证：x509 客户端证书 与 GCP CloudSQL IAM

### 7.1 x509 Client Certificate Authentication

Vault PG 插件支持 PostgreSQL 自身的[客户端 x509 证书认证机制](https://www.postgresql.org/docs/16/libpq-ssl.html#LIBPQ-SSL-CLIENTCERT)。

两种入参方式：

**方式 A：把证书内容内联到 Vault 配置中**（用 `@/path/to/...` 让 CLI 读文件内容）：

```bash
$ vault write database/config/my-postgresql-database \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="postgresql://{{username}}:{{password}}@localhost:5432/database-name?sslmode=verify-full" \
    username="vaultuser" \
    private_key=@/path/to/client.key \
    tls_certificate=@/path/to/client.pem \
    tls_ca=@/path/to/client.ca
```

> `private_key` / `tls_certificate` / `tls_ca` 三字段对应 PostgreSQL 的 `sslkey` / `sslcert` /
> `sslrootcert` 选项；与 PG 原生不同的是，这里传入的是**文件内容本身**，不是文件名。

**方式 B：证书文件直接放在 Vault 服务器本机磁盘上**，连接串里按 PG 标准写绝对路径：

```bash
$ export SSL="sslmode=verify-full&sslrootcert=/path/to/ca.pem&sslcert=/path/to/client.pem&sslkey=/path/to/client.key"
$ vault write database/config/my-postgresql-database \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="postgresql://{{username}}:{{password}}@localhost:5432/database-name?sslmode=verify-full&${SSL}" \
    username="vaultuser"
```

### 7.2 GCP CloudSQL IAM (`auth_type=gcp_iam`)

CloudSQL 上跑的 PostgreSQL 可以让 Vault **不用密码**就连进去——靠 GCP Service Account 的 IAM 身份完成认证。

前置 SQL 权限（在 PG 端执行一次）：

```sql
-- Enable service account to create roles within DB
ALTER USER "<YOUR DB USERNAME>" WITH CREATEROLE;
```

两种凭据来源：

- **Application Default Credentials (ADC)**：让 Vault 进程所在环境自动提供身份；
  连接配置里写 `auth_type="gcp_iam"`，加上 `use_private_ip` / `use_psc` 等 CloudSQL 网络选项
- **直接传服务账号 JSON Key**：`service_account_json="@my_credentials.json"` 把 key 文件内容当成字符串传入

> 认证方式不同，但**完成连接后** Static Role / Dynamic Role 的玩法**与默认密码模式完全一致**。

---

## 8. 路径与 Policy 速查

| 操作 | 路径 | Policy capabilities |
| --- | --- | --- |
| 启用 / 读取 / 禁用引擎 | `sys/mounts/database` | `create` / `read` / `update` / `delete`（按实际 API 动作授予） |
| 写入 / 读取 / 删除连接配置 | `database/config/<name>` | `["create","read","update","delete"]` |
| 列出连接配置 | `database/config` | `["list"]` |
| 轮转 root 密码 | `database/rotate-root/<name>` | `["update"]`（注意上层文档示例用的命令是 `vault write -force database/rotate-root/<name>`） |
| Dynamic Role CRUD | `database/roles/<name>` | `["create","read","update","delete"]` |
| 列出 Dynamic Roles | `database/roles` | `["list"]` |
| **申领** Dynamic 凭据 | `database/creds/<name>` | `["read"]`（应用只读这一条即可） |
| Static Role CRUD | `database/static-roles/<name>` | `["create","read","update","delete"]`（路径名见官方 Rootless Configuration §3 示例 `database/static-roles/my-role`） |
| 列出 Static Roles | `database/static-roles` | `["list"]` |
| 读 Static 当前密码 | `database/static-creds/<name>` | `["read"]`（路径名见官方 Rootless Configuration §4 示例 `vault read database/static-creds/my-role`） |

> 完整字段表见 [PostgreSQL database plugin API](https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql) 与
> 上层 [Database secrets engine API](https://developer.hashicorp.com/vault/api-docs/secret/databases)。

---

## 9. 最容易踩的几个坑

1. **绝对不要把 root 用户挂成 Static Role**——见 §3.2 引文。要轮 root 用 `database/rotate-root/<name>`，
   不要走 `database/static-roles/`。

2. **`{{username}}`、`{{name}}` 与 `{{password}}` 都是 Vault 的占位符，不是 PG 的**——
   `connection_url` 用 `{{username}}` / `{{password}}` 注入 root 连接信息；
   `creation_statements` 用 `{{name}}` / `{{password}}` / 可选 `{{expiration}}` 注入动态账号信息。

3. **onboarding Static Role 默认会立刻把现有密码改掉**——切换前若没让应用先从 Vault 读密码，
  旧密码瞬间失效；在具备这些 onboarding 字段的版本/许可下，存量接管应显式
  `skip_import_rotation=true`，配合 `password=<现有密码>` 平滑切换。

4. **Rootless 模式只支持 Static Role，不支持 Dynamic** —— 见 §6。

5. **`rotation_period` 与 `rotation_schedule` 互斥，必须二选一** —— 见 §5.3。

6. **MongoDB Atlas 不支持轮转 root**，但 PostgreSQL 支持——这是 Capabilities 表里 `Yes` 的实际含义；
   切换到 Atlas 前看一眼上层表。

---

## 10. 与其它章节的关系

```
[2.3 Lease]  ── 本节 Dynamic Role 的 TTL & 自动 DROP ROLE 来源
     │
[3.1 Secrets Engines] ── 引擎挂载与 path 分离的总框架
     │
[3.10 LDAP 引擎] ── 同模型："Vault 代管外部系统的账号生命周期"
     │
[3.14 PostgreSQL 引擎] ◄── 你在这儿
     │
[未来 Database 通用框架专章 / Cloud IAM 联邦] ── 本节 §7.2 GCP IAM 的更深入展开
```

---

## 参考文献

- [PostgreSQL database secrets engine](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)（本节主要来源）
- [Database secrets engine（上层框架）](https://developer.hashicorp.com/vault/docs/secrets/databases)
- [PostgreSQL database plugin API](https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql)
- [Database secrets engine API](https://developer.hashicorp.com/vault/api-docs/secret/databases)
- [Database credential management tutorials](https://developer.hashicorp.com/vault/tutorials/db-credentials)（上层 Database 文档 Tutorial 段所引）
- [pgx 连接串参考](https://pkg.go.dev/github.com/jackc/pgx/stdlib)
- [PostgreSQL connection string](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-postgres"/>
