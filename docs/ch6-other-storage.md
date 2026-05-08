---
order: 65
title: 6.5 其他存储后端：Consul / DynamoDB / Filesystem / In-Memory / PostgreSQL / S3
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.5 其他存储后端：Consul / DynamoDB / Filesystem / In-Memory / PostgreSQL / S3

> **核心结论**：自 Vault 1.4 起，HashiCorp 已正式将 Integrated Storage（Raft）确立为首选生产存储后端；本节列出的六类“其他存储后端”仍然保留在开源版中可用，但各自定位完全不同——Consul 是 1.4 之前历史上的官方推荐方案、DynamoDB 与 PostgreSQL 是社区维护的高可用替代品、Filesystem 适合单节点持久化、In-Memory 仅适合开发实验、S3 仅适合不需要高可用的归档式部署。本节按“顶层 `storage` 块的通用语法 → Integrated 与外部存储的整体取舍 → 六类后端逐一过场”的顺序展开，并在最后给出一份选型对照表与一段动手实验链接，帮助学员在真实排错场景下能正确判断“面前这套配置写得合不合理”。

本节是第 6 章的第五节，承接 6.4 节对 Integrated Storage 的深入展开。学习完 6.4 后，学员已经能够独立搭建并运维一个 Raft 集群；本节的目的不是让学员把每一种外部存储后端都搭一遍——绝大多数情况下生产环境根本不应该选用它们——而是让学员**看到这些配置时能识别得出来、能讲出它们与 Raft 的差别在哪里、能判断对方部署的合理性**。

---

## 1. `storage` 顶层块的通用语法

存储后端通过 Vault 配置文件中的 `storage` 块来配置，块名即后端类型，块体内填写该后端特有的参数：

```hcl
storage [NAME] {
  [PARAMETERS...]
}
```

例如，使用本地文件系统作为存储后端的最小写法是：

```hcl
storage "file" {
  path = "/mnt/vault/data"
}
```

对于那些**同时支持环境变量配置**的参数，环境变量的取值优先级高于配置文件中的取值。

> 第 6.1 节"`storage` 是必填顶层块"已经强调过：每一份合法的 `vault.hcl` 都必须且仅能包含一个 `storage` 块。本节不再赘述启动流程本身，重点放在**块名（`raft` / `consul` / `dynamodb` / `file` / `inmem` / `postgresql` / `s3`）这一字段在不同选型下的含义差异**。

---

## 2. Integrated Storage 与外部存储的整体取舍

HashiCorp 在官方文档中明确给出了选型建议：**对绝大多数用例，应当使用 Vault 内置的 Integrated Storage，而不是再额外配置一套外部系统来承担 Vault 的数据持久化职责**。Integrated Storage 是 Vault 1.4 起内置的"嵌入式数据存储"，在此之前 Consul 是当时官方推荐的存储后端。HCP Vault Dedicated 托管集群也使用 Integrated Storage。

将"Integrated Storage"与统称的"External Storage"对照来看，差别集中在 5 个维度（下表参照官方文档的对比表整理）：

| 对比维度 | Integrated Storage | External Storage |
| :--- | :--- | :--- |
| HashiCorp 是否官方支持 | 是 | 仅有限度支持 |
| 运维复杂度 | 较低，无需额外安装其它软件 | 必须在 Vault 之外另行安装并配置外部存储；如果要做高可用，外部存储自身也必须做成集群 |
| 网络 hop | 少一跳 | Vault 与外部存储之间多一跳网络 |
| 排障与监控 | 只需监控 Vault 本身 | 故障源既可能是 Vault 也可能是外部存储，需要同时监控两套系统 |
| 数据所在位置 | 加密后的 Vault 数据落在跑 Vault 进程的同一台主机上 | 加密后的数据落在外部存储所在的物理主机上，与 Vault 主机分离 |

**因此本节的预期态度是**：除非项目处于"已有一套外部存储、且替换它的迁移成本明显高于继续维护它的成本"这一历史包袱场景，否则新建集群应优先选 `raft`。其余六种后端的存在意义更接近"读懂别人配置 / 维护遗留系统 / 在开发环境里跑实验"，而不是"为新生产环境主动选型"。

![Vault 加密引擎与可插拔存储后端的关系：明文请求经过 Vault 加密层后，才以加密字节落入下方任一选定的存储后端](/images/ch6-other-storage/storage-backend-position.png)

---

## 3. Consul 存储后端

### 3.1 定位与官方支持级别

Consul 存储后端把 Vault 的数据持久化到 Consul 的 KV 存储中。除了提供持久化之外，启用该后端还会把 Vault 自身作为一个带默认健康检查的服务**注册到 Consul 中**。

支持级别上：**Consul 存储后端支持高可用**，并且**由 HashiCorp 官方支持**。

最小配置：

```hcl
storage "consul" {
  address = "127.0.0.1:8500"
  path    = "vault/"
}
```

### 3.2 服务发现与三类服务名

一旦 Vault 正常 unseal 并完成与 Consul 的注册，可通过下列 DNS 名访问到不同状态的 Vault 实例：

- `active.vault.service.consul`：当前处于 active 状态、可用且已 unseal 的 Vault 节点；
- `standby.vault.service.consul`：处于 standby（备用）模式、已 unseal 的 Vault 节点；
- `vault.service.consul`：所有处于健康状态、已 unseal 的 Vault 节点。

被 sealed 的 Vault 实例会**主动把自己标记为不健康**，从而避免在 Consul 的服务发现层中被返回。

### 3.3 Vault 多 listener 时的归属声明

如果一份 `vault.hcl` 配置了多个 listener，必须使用顶层的 `api_addr` 与 `cluster_addr` 字段**显式声明**应当向 Consul 注册和广告哪一个地址，否则 Vault 无法判断该把哪个 listener 作为对外服务点暴露给集群其它成员。

### 3.4 关键参数速览

下列参数较为关键，建议在阅读他人配置时优先核对（完整列表见官方 `consul` parameters 一节）：

- `address`（默认 `127.0.0.1:8500`）：Consul agent 的地址。**官方建议与本地 Consul agent 通信，而不是直接连 Consul server**；该字段也接受 unix socket 路径。
- `path`（默认 `vault/`）：Vault 数据在 Consul KV 存储中的路径前缀。
- `scheme`（默认 `http`）：与 Consul 通信使用的协议。**强烈建议非本地连接使用 `https`**；如使用 unix socket 则忽略此项。
- `service`（默认 `vault`）：注册到 Consul 中的服务名。
- `disable_registration`（默认 `false`）：是否关闭 Vault 自身向 Consul 注册的行为。
- `consistency_mode`（默认 `default`）：取值为 `default` 或 `strong`，对应 Consul 的一致性模式。
- `token`（默认空）：Consul ACL token；**这并不是 Vault token**，可通过环境变量 `CONSUL_HTTP_TOKEN` 提供。
- `session_ttl`（默认 `15s`）/`lock_wait_time`（默认 `15s`）：分别对应 Consul session 的最小 TTL 与锁获取等待时间。
- `max_parallel`（默认 `128`）：同时向 Consul 发起的最大并发请求数；**Consul agent 一侧的 `http_max_conns_per_client` 必须配合调整以承接该并发量**。
- TLS 相关：`tls_ca_file`、`tls_cert_file`、`tls_key_file`、`tls_min_version`（默认 `tls12`）、`tls_skip_verify`（默认 `false`，**强烈不建议开启**）。

### 3.5 Consul ACL 最低权限

如果 Consul 启用了 ACL，则承载 Vault 的 token 必须至少具备以下能力（以服务名 `vault`、KV 前缀 `vault/` 为例）。Consul 1.4+ 的 ACL 语法示例如下：

```json
{
  "key_prefix": {
    "vault/": { "policy": "write" }
  },
  "service": {
    "vault": { "policy": "write" }
  },
  "agent_prefix": {
    "": { "policy": "read" }
  },
  "session_prefix": {
    "": { "policy": "write" }
  }
}
```

> 关于 Integrated Storage 与 Consul 作为 Vault 存储的细化对比，可参考官方文档的"Integrated storage vs. consul as Vault storage"小节中的对比表：在使用 Consul 作为存储时，需要部署 Vault 集群 **加** 一套 Consul 集群，并且**应使用一套专用 Consul 集群承担 Vault 存储职责，而不要复用承担服务发现 / 服务网格的 Consul**；另外，**单条数据消息的最大尺寸：Integrated Storage 默认 1 MiB（可由 `max_entry_size` 调整），Consul 为 512 KiB（可由 `kv_max_value_size` 调整）**。

---

## 4. DynamoDB 存储后端

### 4.1 定位与官方支持级别

DynamoDB 存储后端把 Vault 数据持久化到 AWS DynamoDB 表中。

支持级别上：**DynamoDB 后端支持高可用**——但官方文档同时给出明确的工程警告：**因为 DynamoDB 使用 Vault 节点本机时间来实现锁的会话生命周期，因此 Vault 节点之间显著的时钟漂移可能导致锁竞争出问题**。该后端**由社区维护**，已经经过 HashiCorp 员工评审但他们对相关技术不一定熟悉，遇到问题可能会被引导回到原作者处寻求支持。

最小高可用示例：

```hcl
storage "dynamodb" {
  ha_enabled = "true"
  region     = "us-west-2"
  table      = "vault-data"
}
```

### 4.2 关键参数速览

- `table`（默认 `vault-dynamodb-backend`）：用于存储 Vault 数据的 DynamoDB 表名。**如果指定的表不存在，Vault 会在初始化时自动创建**。也可通过环境变量 `AWS_DYNAMODB_TABLE` 提供。
- `ha_enabled`（默认 `false`）：是否启用高可用；可通过环境变量 `DYNAMODB_HA_ENABLED` 提供。
- `region`（默认 `us-east-1`）：AWS 区域；可通过 `AWS_DEFAULT_REGION` 提供。
- `endpoint`（默认空）：兼容 DynamoDB API 的替代端点；可通过 `AWS_DYNAMODB_ENDPOINT` 提供。
- `billing_mode`（默认 `PROVISIONED`）：可选 `PROVISIONED` 或 `PAY_PER_REQUEST`；可通过 `AWS_DYNAMODB_BILLING_MODE` 提供。
- `read_capacity` / `write_capacity`（默认均为 `5`）：仅当 Vault 自己创建表时生效；**若表已存在且 `dynamodb_allow_updates` 未设置，则这两个参数无效**。
- `dynamodb_allow_updates`：若设置，则当传入的 billing mode 或读 / 写容量与现有表不同时，Vault 会尝试更新表。
- `max_parallel`（默认 `128`）：最大并发请求数。
- 认证相关：`access_key`、`secret_key`、`session_token`，对应环境变量 `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_SESSION_TOKEN`；**若 Vault 跑在 EC2 上且这两个 key 留空，Vault 会尝试通过 EC2 instance metadata service 获取凭据**。

### 4.3 表结构与最低 IAM 权限

如果选择在 Vault 启动之前手动建表，DynamoDB 表必须满足以下结构：**主分区键名为 `Path`、类型为字符串；主排序键名为 `Key`、类型为字符串**。

如果表不存在，Vault 会按照 `billing_mode`、`read_capacity`、`write_capacity` 配置项的取值自动创建。Vault 默认情况下**不会修改已存在的表**，需要修改时必须显式打开 `dynamodb_allow_updates`。

操作 DynamoDB 所需的最低 IAM 权限集合见官方文档 `## Required AWS permissions` 段，包含 `dynamodb:DescribeLimits`、`dynamodb:DescribeTimeToLive`、`dynamodb:ListTagsOfResource`、`dynamodb:DescribeReservedCapacityOfferings`、`dynamodb:DescribeReservedCapacity`、`dynamodb:ListTables`、`dynamodb:BatchGetItem`、`dynamodb:BatchWriteItem`、`dynamodb:CreateTable`、`dynamodb:DeleteItem`、`dynamodb:GetItem`、`dynamodb:GetRecords`、`dynamodb:PutItem`、`dynamodb:Query`、`dynamodb:UpdateItem`、`dynamodb:Scan`、`dynamodb:DescribeTable`、`dynamodb:UpdateTable` 这一组动作。

---

## 5. PostgreSQL 存储后端

### 5.1 定位与官方支持级别

PostgreSQL 存储后端把 Vault 数据持久化到 PostgreSQL 服务器或集群中。

支持级别上：**PostgreSQL 后端支持高可用，但要求 PostgreSQL 9.5 或以上版本**；**该后端由社区维护**。

最小配置：

```hcl
storage "postgresql" {
  connection_url = "postgres://user123:secret123!@localhost:5432/vault"
}
```

注意 PostgreSQL 存储后端插件**默认会尝试以 SSL 连接数据库**；如果数据库未启用 SSL，则必须在 `connection_url` 中明确禁用 SSL。

### 5.2 必须手工创建的表与索引

**PostgreSQL 存储后端不会自动创建任何表**——这是它与 DynamoDB 后端最显著的运维差异点。学员在为他人或自己的项目搭建该后端时，必须先以下列 SQL 在目标库中创建表：

主数据表：

```sql
CREATE TABLE vault_kv_store (
  parent_path TEXT COLLATE "C" NOT NULL,
  path        TEXT COLLATE "C",
  key         TEXT COLLATE "C",
  value       BYTEA,
  CONSTRAINT pkey PRIMARY KEY (path, key)
);

CREATE INDEX parent_path_idx ON vault_kv_store (parent_path);
```

如果启用了高可用，还需要额外建一张锁表：

```sql
CREATE TABLE vault_ha_locks (
  ha_key      TEXT COLLATE "C" NOT NULL,
  ha_identity TEXT COLLATE "C" NOT NULL,
  ha_value    TEXT COLLATE "C",
  valid_until TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT ha_key PRIMARY KEY (ha_key)
);
```

如果使用的是 9.5 之前的 PostgreSQL，还需要额外创建一个 `vault_kv_put` 函数来手动模拟 9.5 引入的 `ON CONFLICT` upsert 行为。

### 5.3 关键参数速览

- `connection_url`（必填）：PostgreSQL 连接串，可通过环境变量 `VAULT_PG_CONNECTION_URL` 提供。
- `table`（默认 `vault_kv_store`）：写入 Vault 数据的表名，**该表必须已存在**。
- `ha_enabled`（默认未启用）：是否启用高可用；**要求 PostgreSQL 9.5 或更高版本**。
- `ha_table`（默认 `vault_ha_locks`）：高可用锁表的表名，**该表必须已存在**。
- `max_idle_connections`：连接池中保持空闲的最大连接数（**Vault 1.2 起支持**）。
- `max_parallel`（默认 `128`）：与 PostgreSQL 之间的最大并发请求数。
- `auth_mode`：可取 `standard` / `aws_iam` / `azure_msi` / `gcp_iam`，分别对应"标准用户名密码"以及三大云厂商的 IAM / 托管身份认证；其中 `aws_iam` 模式必须额外提供 `aws_db_region`，`azure_msi` 模式可选地提供 `azure_client_id` 来切换"用户分配 / 系统分配"的 Managed Identity。

### 5.4 SSL 配置示例

推荐使用完整 SSL 校验：

```hcl
storage "postgresql" {
  connection_url = "postgres://user:pass@localhost:5432/database?sslmode=verify-full"
}
```

如确需关闭 SSL（**不推荐**），把 `verify-full` 替换为 `disable`。

---

## 6. Filesystem 存储后端

### 6.1 定位与官方支持级别

Filesystem 存储后端使用标准的目录结构把 Vault 数据存在本机文件系统上。它适用于"持久化的单节点部署"以及"在本地做开发、对持久性要求不高"两种场景。

支持级别上：**Filesystem 后端不支持高可用**，但**由 HashiCorp 官方支持**。

唯一的配置参数是 `path`：磁盘上数据存放目录的**绝对路径**。如果该目录不存在，Vault 会自动创建。

```hcl
storage "file" {
  path = "/mnt/vault/data"
}
```

### 6.2 安全提示

虽然 Vault 数据本身**在静态状态下是加密的（encrypted at rest）**，但仍应采取适当措施保护对底层文件系统的访问权限。

> 实践上：所选 `path` 目录的属主应是运行 Vault 的系统账户；权限位推荐 `0700`，避免任何同主机上的其它用户读取已加密数据后再针对密文进行离线分析。

---

## 7. In-Memory 存储后端

### 7.1 定位与官方支持级别

In-Memory 存储后端把 Vault 数据**全部存在运行 Vault 的同一台机器的内存中**，适合开发与实验，**强烈不建议用于生产**——所有数据在 Vault 进程或宿主机重启时都会丢失。

支持级别上：**In-Memory 后端不支持高可用**，**不推荐用于生产**，但**由 HashiCorp 官方支持**。

它**没有任何配置参数**，激活方式即一行：

```hcl
storage "inmem" {}
```

> 注意：`vault server -dev` 开发模式背后正是用 `inmem` 后端起一个非持久化、自动 unseal、根 token 已知的 Vault 进程。一旦在生产场景里有人提交了 `storage "inmem" {}`，应当将其视作配置错误立刻拦回。

---

## 8. S3 存储后端

### 8.1 定位与官方支持级别

S3 存储后端把 Vault 数据持久化到 Amazon S3 桶中。

支持级别上：**S3 后端不支持高可用**；**由社区维护**。

最小示例：

```hcl
storage "s3" {
  access_key = "abcd1234"
  secret_key = "defg5678"
  bucket     = "my-bucket"
}
```

### 8.2 关键参数速览

- `bucket`（必填）：S3 桶名；可通过环境变量 `AWS_S3_BUCKET` 提供。
- `endpoint`（默认空）：兼容 S3 API 的替代端点；可通过 `AWS_S3_ENDPOINT` 提供。
- `region`（默认 `us-east-1`）：AWS 区域；优先级为环境变量 `AWS_REGION` > `AWS_DEFAULT_REGION`。
- `access_key` / `secret_key` / `session_token`：可通过环境变量、AWS 凭据文件或 IAM 角色提供；EC2 上若留空，则尝试从 EC2 实例 metadata 获取凭据。
- `max_parallel`（默认 `128`）：与 S3 之间的最大并发请求数。
- `s3_force_path_style`（默认 `false`）：是否在指定 endpoint 时使用 path-style 而非 host-style 桶名寻址。
- `disable_ssl`（默认 `false`）：是否关闭 endpoint 的 SSL；**生产场景强烈不建议关闭**。
- `kms_key_id`（默认空）：用于在 S3 后端加密数据的 KMS 密钥 ID 或别名；启用时 Vault 必须对该 KMS key 拥有 `kms:Encrypt`、`kms:Decrypt`、`kms:GenerateDataKey` 权限；可使用 `alias/aws/s3` 引用账号默认密钥。
- `path`（默认空）：S3 桶内 Vault 数据的路径前缀。

### 8.3 KMS 加密示例

使用账号默认 S3 KMS key 加密：

```hcl
storage "s3" {
  access_key = "abcd1234"
  secret_key = "defg5678"
  bucket     = "my-bucket"
  kms_key_id = "alias/aws/s3"
}
```

使用客户托管的 KMS key（替换为该 key 的 ID）：

```hcl
storage "s3" {
  access_key = "abcd1234"
  secret_key = "defg5678"
  bucket     = "my-bucket"
  kms_key_id = "001234ac-72d3-9902-a3fc-0123456789ab"
}
```

> **请特别留意**：S3 后端**不支持高可用**这一限制，意味着即便底层 S3 桶具备 99.999999999% 的耐久度，Vault 自身在该后端下也只能以单节点形式运行。对外宣称 SLA 时不能把 S3 自身的可用性等同于 Vault 集群的可用性。

---

## 9. 选型决策对照表

把上述六类后端 + Integrated Storage 一并放入下表，方便在阅读他人配置或评审架构方案时快速判断：

| 块名 | 是否支持 HA | 支持级别 | 典型适用场景 | 是否官方推荐用于新生产环境 |
| :--- | :--- | :--- | :--- | :--- |
| `raft`（Integrated Storage） | 是 | HashiCorp 官方 | 几乎所有新生产部署 | 是 |
| `consul` | 是 | HashiCorp 官方 | Vault 1.4 之前的历史方案；现存的 Consul + Vault 联用环境 | 否（迁移至 raft） |
| `dynamodb` | 是（受时钟漂移影响） | 社区 | AWS 内、且组织已经标准化 DynamoDB 的环境 | 否（优先 raft） |
| `postgresql` | 是（要求 9.5+） | 社区 | 已有 PostgreSQL 集群、希望把 Vault 数据并入既有备份体系 | 否（优先 raft） |
| `file` | 否 | HashiCorp 官方 | 单节点持久化、本地实验 | 否（仅限单节点） |
| `inmem` | 否 | HashiCorp 官方 | 开发 / 测试 / 演示 | 否（绝不可用于生产） |
| `s3` | 否 | 社区 | 不需要 HA 的归档式部署 | 否（缺少 HA） |

---

## 10. 动手实验

光看不练记不住——本节配套实验在同一台 Killercoda 主机上依次切换五种最具代表性的"非 raft"后端，让学员**亲眼看到**它们在持久化语义、HA 能力、运维步骤上的差异：

1. **Filesystem** 后端：写入 KV 数据 → 重启 Vault 进程 → 验证数据仍在；
2. **In-Memory** 后端：写入 KV 数据 → 重启 Vault 进程 → 验证数据**全部丢失**；
3. **PostgreSQL** 后端：手工执行 `CREATE TABLE` → 启动 Vault → 写入 KV 数据 → 直接到 PostgreSQL 表里 `SELECT` 出加密后的字节，亲手验证"密文落在哪里"；
4. **S3** 后端：通过本地 [LocalStack](https://www.localstack.cloud/)（监听 :4566 的本机 AWS API 兼容服务）模拟 AWS S3，预创建 bucket → 启动 Vault → 直接 `awslocal s3api list-objects` 看到 Vault 写入的密文对象；
5. **DynamoDB** 后端：同样通过本地 LocalStack 模拟 AWS DynamoDB，启动 Vault → 由 Vault 自动建表（与 PostgreSQL 后端形成最直观的运维差异）→ 直接 `awslocal dynamodb scan` 看到 `Path` / `Key` / `Value` 三列的密文行。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-other-storage" title="实验：其他存储后端实操（Filesystem / In-Memory / PostgreSQL / S3 / DynamoDB）" />

---

## 11. 小结

- `storage` 是 Vault 配置文件中的必填顶层块，块名即后端类型；同名环境变量优先级高于配置文件。
- 自 Vault 1.4 起，HashiCorp 把 Integrated Storage（`raft`）确立为首选生产方案；本节列出的其他六种后端在新生产部署中都**不是优先选项**。
- 各后端的 HA 与支持级别差异巨大：`raft` / `consul` 是 HashiCorp 官方 + HA；`dynamodb` / `postgresql` 是社区 + HA；`file` / `inmem` 是 HashiCorp 官方但**无 HA**；`s3` 是社区但**无 HA**。
- 维护遗留 / 排错时几个最容易踩中的细节：Consul 后端应连本地 agent 而非直连 Consul server、Consul ACL token 不是 Vault token、DynamoDB 锁依赖节点本机时钟、PostgreSQL 后端**不会自动建表**、In-Memory 数据在重启后**全部丢失**、S3 后端**不支持 HA**。
