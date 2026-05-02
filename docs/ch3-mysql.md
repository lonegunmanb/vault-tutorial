---
order: 315
title: 3.15 MySQL/MariaDB 数据库机密引擎：动态账号、通配授权与云 IAM
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.15 MySQL/MariaDB 数据库机密引擎：动态账号、通配授权与云 IAM

> **核心结论**：MySQL/MariaDB 插件是 Vault Database secrets engine 支持的数据库插件之一；它根据你在 Vault 里配置的 role，动态生成可登录 MySQL 的账号和密码，并且官方页面明确写到它也支持 Static Roles。你可以把它理解成：Vault 不保存你的业务数据，只保存“怎么替你去 MySQL 建账号、授权、删账号”的规则。

> **本文的事实边界**：这一节严格只引用两份官方原文：[MySQL/MariaDB database secrets engine](https://raw.githubusercontent.com/hashicorp/web-unified-docs/refs/heads/main/content/vault/v2.x/content/docs/secrets/databases/mysql-maria.mdx) 与 [MySQL/MariaDB database plugin HTTP API](https://raw.githubusercontent.com/hashicorp/web-unified-docs/refs/heads/main/content/vault/v2.x/content/api-docs/secret/databases/mysql-maria.mdx)。官方 MySQL/MariaDB 页只给出 Static Roles “支持”的结论，没有在这两页展开 Static Role 的创建参数，所以本文不会把上层 Database 文档中的 static-role 字段硬塞进来。

参考：
- [MySQL/MariaDB database secrets engine](https://developer.hashicorp.com/vault/docs/secrets/databases/mysql-maria)
- [MySQL/MariaDB database plugin HTTP API](https://developer.hashicorp.com/vault/api-docs/secret/databases/mysql-maria)
- 对照：[3.14 PostgreSQL 数据库机密引擎](/ch3-postgres)
- 概念基础：[3.1 Secrets Engines](/ch3-secrets-engines)、[2.3 Lease](/ch2-lease)

![MySQL/MariaDB Database Secrets Engine flow](/images/ch3-mysql/mysql-dynamic-credential-flow.png)

> 手绘风格绘图指令：画一个左侧“应用/Vault token”、中间“Vault database/ 引擎”、右侧“MySQL/MariaDB”的三栏流程图；箭头 1 是应用读 `database/creds/my-role`，箭头 2 是 Vault 按 `creation_statements` 到 MySQL 执行 `CREATE USER` 和 `GRANT SELECT`，箭头 3 是 Vault 把 `username/password/lease_id` 返回给应用，箭头 4 是撤销凭据时按 `revocation_statements` 执行 `DROP USER`。画风像白板手绘，线条略微不齐，重点标出 `{{name}}` 和 `{{password}}` 是 Vault 替换的占位符。

> 核查注：图中若出现“Lease 到期后清理用户”的表达，是为了和 [2.3 Lease](/ch2-lease) 的上层租约机制衔接；这两份 MySQL/MariaDB 原文只直接展示 `lease_*` 输出字段，并说明 `revocation_statements` 是撤销用户时执行的语句。

---

## 1. 一句话定位：这是 Database 引擎下的 MySQL/MariaDB 插件

Vault 的 Database secrets engine 里有 MySQL 插件；这个插件的任务，是根据 Vault role 里的 SQL 模板为 MySQL 动态生成数据库凭据。官方 API 页也用同样的说法描述：MySQL database plugin 是 database secrets engine 支持的插件之一，会基于配置好的 role 动态生成 MySQL 凭据。

这个插件不是只有一个名字：Vault 内置了 `mysql-database-plugin`、`mysql-aurora-database-plugin`、`mysql-rds-database-plugin`、`mysql-legacy-database-plugin` 四个实例；官方说它们面向略有差异的 MySQL driver，唯一差别是生成用户名的长度，因为不同 MySQL 版本接受的用户名长度不同。

| 插件名 | 默认用户名模板体现的长度 | 适合理解成什么 |
| --- | --- | --- |
| `mysql-database-plugin` | 模板最后 `truncate 32`，示例用户名如 `v-token-myrolename-jNFRlKsZZMxJE` | 通用 MySQL/MariaDB 插件，用户名可到 32 字符这一档 |
| `mysql-aurora-database-plugin` | 与 RDS、legacy 同组，模板最后 `truncate 16` | 面向 Aurora driver 变体，用户名更短 |
| `mysql-rds-database-plugin` | 与 Aurora、legacy 同组，模板最后 `truncate 16` | 面向 RDS driver 变体，用户名更短 |
| `mysql-legacy-database-plugin` | 与 Aurora、RDS 同组，模板最后 `truncate 16` | 面向旧版本 MySQL driver 变体，用户名更短 |

官方 Setup 示例使用 `mysql-database-plugin`；同一页还列出 Aurora、RDS 与 legacy 三个插件实例，并说明这些实例的差异在生成用户名长度。至于生产环境如何在四个插件之间选型，这两份 MySQL/MariaDB 原文没有给出更细的决策规则。

---

## 2. 插件能力速览

官方 Capabilities 表把 MySQL/MariaDB 插件的能力列为：Root Credential Rotation = Yes，Dynamic Roles = Yes，Static Roles = Yes，Username Customization = Yes (1.7+)；插件名一栏写的是 “Depends”，也就是要看上一节列出的具体 MySQL 插件实例。

| 能力 | 官方结论 | 这对学习者意味着什么 |
| --- | --- | --- |
| Root Credential Rotation | Yes | Vault 可以轮转连接配置里的 root 凭据；MySQL 5.7+ 默认用 `ALTER USER`，MySQL 5.6 要配置旧式 `SET PASSWORD` 语句 |
| Dynamic Roles | Yes | `vault read database/creds/<role>` 可以触发 Vault 按 SQL 模板新建一个短寿命 MySQL 用户 |
| Static Roles | Yes | 官方 MySQL/MariaDB 页确认插件支持 Static Roles，但这两份页面没有列出 static role 的具体创建字段 |
| Username Customization | Yes (1.7+) | 可以通过 `username_template` 控制动态用户名生成模板；API 页列出了默认模板 |

这四项能力里，本文会完整展开官方 MySQL/MariaDB 页实际给出命令和参数的部分：启用引擎、写连接、创建 Dynamic Role、读取凭据、x509、wildcard grant、MySQL 5.6 root rotation、GCP CloudSQL IAM，以及 API 页列出的 MySQL 插件专属参数。

---

## 3. Setup：从 `database/` 到 `database/creds/<role>`

### 3.1 启用 `database/` 引擎

官方第一步是启用 database secrets engine：

```bash
$ vault secrets enable database
Success! Enabled the database secrets engine at: database/
```

默认情况下，secrets engine 会按引擎名启用到 `database/`；如果要挂到别的路径，使用 `-path` 参数。

### 3.2 写入 MySQL 连接配置

官方第二步是把插件名、连接串、允许的 role 名以及 root 凭据写入 `database/config/<name>`；示例里的 `<name>` 是 `my-mysql-database`。

```bash
$ vault write database/config/my-mysql-database \
    plugin_name=mysql-database-plugin \
    connection_url="{{username}}:{{password}}@tcp(127.0.0.1:3306)/" \
    allowed_roles="my-role" \
    username="vaultuser" \
    password="vaultpass"
```

这条命令里最容易看错的是 `connection_url`：API 页说它是 MySQL DSN，支持用 `{{field_name}}` 形式把 `username` 和 `password` 参数模板化进去；如果要做 root credential rotation，模板化的 connection URL 是必需的。

| 参数 | 怎么理解 |
| --- | --- |
| `plugin_name` | 选择 MySQL 插件实例；官方基础示例使用 `mysql-database-plugin` |
| `connection_url` | MySQL DSN，可写 `{{username}}` / `{{password}}` 占位符；root credential rotation 需要模板化连接串 |
| `allowed_roles` | 官方示例把它写成 `my-role`，下一步也创建同名 Vault role；它是连接配置示例的一部分 |
| `username` | 连接 URL 中使用的 root credential username |
| `password` | 连接 URL 中使用的 root credential password |
| `max_open_connections` | 到数据库的最大打开连接数，默认 `4`；API 示例里写了 `5` |
| `max_idle_connections` | 最大空闲连接数，默认 `0`；`0` 使用 `max_open_connections`，负数禁用空闲连接，大于 `max_open_connections` 会被降到相等 |
| `max_connection_lifetime` | 单条连接可复用的最长时间，默认 `0s`；小于等于 `0s` 表示连接永久复用 |
| `auth_type` | 设为 `gcp_iam` 时启用到 Google CloudSQL 实例的 IAM 认证 |
| `service_account_json` | GCP Service Account 的 JSON 编码凭据；要求 `auth_type=gcp_iam` |
| `use_private_ip` | 连接 CloudSQL Private IP 的选项；要求 `auth_type=gcp_iam` |
| `use_psc` | 连接 CloudSQL Private Service Connect 的选项；要求 `auth_type=gcp_iam` |
| `tls_certificate_key` | x509 客户端证书连接用的 PEM 内容，要求私钥和证书合并在一起 |
| `tls_ca` | 用来验证 MySQL 服务器证书的 PEM 编码 CA 内容 |
| `tls_server_name` | 要求服务器证书里存在的 Subject Alternative Name |
| `tls_skip_verify` | 设为 `true` 会关闭服务器证书校验；官方明确说生产环境不建议这样做 |
| `username_template` | 描述动态用户名生成方式的模板 |
| `disable_escaping` | 关闭 username/password 字段中特殊字符的 escaping，默认 `false` |

### 3.3 创建 Dynamic Role

官方第三步是创建 `database/roles/<role>`：role 名在 Vault 里只是一个名字，真正创建 MySQL 用户时执行的是你写在 `creation_statements` 里的 SQL。

```bash
$ vault write database/roles/my-role \
    db_name=my-mysql-database \
    creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" \
    default_ttl="1h" \
    max_ttl="24h"
Success! Data written to: database/roles/my-role
```

`creation_statements` 是必填项，表示创建并配置用户时要发给数据库执行的语句；它可以是分号分隔字符串、base64 后的分号分隔字符串、序列化 JSON 字符串数组，或者 base64 后的序列化 JSON 字符串数组。

在 `creation_statements` 里，`{{name}}` 和 `{{password}}` 会被 Vault 替换；API 页还说明生成的密码是随机的 20 位字母数字字符串。

`revocation_statements` 是可选项，表示撤销用户时发给数据库的语句；它也支持分号分隔、base64、JSON 数组和 base64 JSON 数组，且会替换 `{{name}}`；如果不提供，默认使用通用的 drop user 语句。

API 页还特别说明：下面列出的 statement 类型就是这个插件支持的 statement 类型；如果列表里没提到，就表示插件不支持那种 statement。

---

## 4. Usage：读 `/creds`，拿到短寿命账号

当 secrets engine 配好，并且某个用户或机器拿到了有正确权限的 Vault token 后，就可以生成数据库凭据。

官方用 `vault read database/creds/my-role` 申领一份凭据；输出里有 `lease_id`、`lease_duration`、`lease_renewable`、`password` 和 `username`。

```bash
$ vault read database/creds/my-role
Key                Value
---                -----
lease_id           database/creds/my-role/2f6a614c-4aa2-7b19-24b9-ad944a8d4de6
lease_duration     1h
lease_renewable    true
password           yY-57n3X5UQhxnmFRP3f
username           v_vaultuser_my-role_crBWVqVh2Hc1
```

你可以把这一刻理解成“Vault 临时替应用在 MySQL 里办了一张带租约信息的门禁卡”：卡号是 `username`，卡密是 `password`，输出里带 `lease_id`、`lease_duration` 和 `lease_renewable`。官方示例中 role 写了 `default_ttl="1h"`、`max_ttl="24h"`，Usage 输出显示 `lease_duration 1h`；这两份 MySQL/MariaDB 原文只把两者并列展示，没有展开 TTL 如何计算成 Lease 的完整因果链，严格解释要看上层 Database engine / Lease 文档。

---

## 5. x509 客户端证书认证

MySQL/MariaDB 插件支持 MySQL 的 x509 client-side certificate authentication；官方给出的做法是在连接配置里加入 `tls_certificate_key` 和 `tls_ca`。

```bash
$ vault write database/config/my-mysql-database \
    plugin_name=mysql-database-plugin \
    allowed_roles="my-role" \
    connection_url="user:password@tcp(localhost:3306)/test" \
    tls_certificate_key=@/path/to/client.pem \
    tls_ca=@/path/to/client.ca
```

这里的 `tls_certificate_key` 对应 MySQL 的 `ssl-cert` 与 `ssl-key` 合并形式，`tls_ca` 对应 MySQL 的 `ssl-ca`；Vault 参数传的是这些文件的内容，不是文件名，所以它们和 MySQL 原生命令行选项是相互独立的。

API 页还列出 `tls_server_name` 与 `tls_skip_verify`：前者指定服务器证书里应出现的 Subject Alternative Name，后者关闭服务器证书校验，而且官方明确说不建议在生产环境把它设为 `true`。

---

## 6. Wildcard grant：给一组数据库授权

MySQL 支持在 grant statements 里使用通配符；这在应用需要访问 MySQL 里大量数据库时会用上。官方举例说，如果你想让 Vault 创建的用户访问所有以 `fooapp_` 开头的数据库，可以在 grant 语句里使用通配符。

```sql
CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON `fooapp\_%`.* TO '{{name}}'@'%';
```

MySQL 要求放通配符的那一段写在反引号里；如果你把这段 SQL 直接贴到 Vault CLI，shell 会把反引号里的内容当作要执行的命令，所以官方建议最简单的绕法是把 creation statement 先 base64，再交给 Vault。

```bash
$ vault write database/roles/my-role \
    db_name=mysql \
    creation_statements="Q1JFQVRFIFVTRVIgJ3t7bmFtZX19J0AnJScgSURFTlRJRklFRCBCWSAne3twYXNzd29yZH19JzsgR1JBTlQgU0VMRUNUIE9OIGBmb29hcHBcXyVgLiogVE8gJ3t7bmFtZX19J0AnJSc7" \
    default_ttl="1h" \
    max_ttl="24h"
```

API 页也印证了这个写法：`creation_statements` 可以接收 base64-encoded semicolon-separated string，所以官方 wildcard 示例不是“特殊技巧”，而是 API 明确支持的输入格式。

![Wildcard grant statement](/images/ch3-mysql/mysql-wildcard-grant.svg)

> 手绘风格绘图指令：画一排三个数据库桶，名字分别是 `fooapp_a`、`fooapp_b`、`barapp_a`；一把钥匙从 Vault 指向前两个桶，钥匙标签写 `GRANT SELECT ON \`fooapp\_%\`.*`，第三个桶旁边画一个小叉。旁边补一个小 shell 气泡：“反引号会被 shell 解释，所以把 SQL 先 base64”。

---

## 7. Root credential rotation：MySQL 5.7+ 与 MySQL 5.6 的差异

官方写明：MySQL 默认 root rotation 使用 MySQL 5.7 及以上版本的 `ALTER USER` 语法；如果是 MySQL 5.6，就必须通过 `root_rotation_statements` 配置旧的 `SET PASSWORD` 语法。

```bash
$ vault write database/config/my-mysql-database \
    plugin_name=mysql-database-plugin \
    connection_url="{{username}}:{{password}}@tcp(127.0.0.1:3306)/" \
    root_rotation_statements="SET PASSWORD = PASSWORD('{{password}}')" \
    allowed_roles="my-role" \
    username="root" \
    password="mysql"
```

这段示例的重点不是让你在新 MySQL 上也写 `SET PASSWORD`，而是提醒你：MySQL 版本会影响 root rotation SQL；MySQL 5.7+ 走默认 `ALTER USER`，MySQL 5.6 才需要上面的 `root_rotation_statements`。

官方还把 “Database Root Credential Rotation” 教程作为进一步参考，但在这两份 MySQL/MariaDB 原文里，实际给出的 MySQL 专属差异就是 5.6 的 `SET PASSWORD` 配置。

---

## 8. GCP CloudSQL IAM：不用普通密码连接 Cloud SQL

官方的 Cloud DB IAM 小节先说：除了 Google CloudSQL 文档要求的 IAM role 外，服务账号对应的数据库用户还需要一些 SQL 权限，Vault 最小功能需要的示例是 `GRANT SELECT, CREATE, CREATE USER ... WITH GRANT OPTION`；具体 role SQL 写得越复杂，可能还需要更多权限。

```sql
-- Enable service account to create users within DB
GRANT SELECT, CREATE, CREATE USER ON <database>.<object> TO "test-user"@"%" WITH GRANT OPTION;
```

GCP IAM 的 setup 仍然先启用 `database/` 引擎；官方再次说明默认路径是引擎名，换路径用 `-path`。

官方接着给出 ADC 方式：在连接配置里显式写 `auth_type="gcp_iam"`，并使用 Application Default Credentials；这里有一个很关键的小注记，Google Cloud IAM 的协议是 `cloudsql-mysql`，不是普通的 `tcp`。

> 核查注：API 文档 `auth_type` 参数说明中的 `here` 链接在官方原文里指向 `.../postgres/authentication`；本文按官方原文记录 `auth_type="gcp_iam"` 的参数含义，CloudSQL MySQL 的连接命令形状仍以引擎文档 GCP IAM Setup 示例为准。

```bash
$ vault write database/config/my-mysql-database \
    plugin_name="mysql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="user@cloudsql-mysql(project:region:instance)/mysql" \
    auth_type="gcp_iam" \
    use_private_ip="false" \
    use_psc="false"
```

如果不靠 ADC，也可以把服务账号凭据作为 encoded JSON string 传入；官方示例使用 `service_account_json="@my_credentials.json"`，API 页同时说明该参数要求 `auth_type` 为 `gcp_iam`。

```bash
$ vault write database/config/my-mysql-database \
    plugin_name="mysql-database-plugin" \
    allowed_roles="my-role" \
    connection_url="user@cloudsql-mysql(project:region:instance)/mysql" \
    auth_type="gcp_iam" \
    use_private_ip="false" \
    use_psc="false" \
    service_account_json="@my_credentials.json"
```

GCP IAM 模式下创建 role 时，官方示例明确覆盖了默认 revocation statements，让 Vault 撤销时执行 `DROP USER '{{name}}'@'%';`。

```bash
$ vault write database/roles/my-role \
    db_name=my-mysql-database \
    creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" \
    revocation_statements="DROP USER '{{name}}'@'%';" \
    default_ttl="1h" \
    max_ttl="24h"
```

完成配置后，官方说像之前一样读取 `database/creds/my-role` 生成凭据；示例输出仍然包含 `lease_id`、`lease_duration`、`lease_renewable`、`password`、`username`。

---

## 9. 路径速查

MySQL/MariaDB API 页列出的连接配置接口是 `POST /database/config/:name`；这对应 CLI 示例里的 `vault write database/config/my-mysql-database ...`。下面表格中，`database/roles/<role>` 和 `database/creds/<role>` 来自引擎文档 CLI 示例，不是 MySQL/MariaDB API 页路径表单独列出的接口。

| 你要做什么 | CLI 路径 | HTTP/API 证据 |
| --- | --- | --- |
| 写连接配置 | `database/config/<name>` | API 页列出 `POST /database/config/:name`；引擎文档示例写 `database/config/my-mysql-database` |
| 写 Dynamic Role | `database/roles/<role>` | 引擎文档示例写 `database/roles/my-role`；API 页只说明 statements 在 role creation 时配置 |
| 申领动态凭据 | `database/creds/<role>` | 引擎文档 Usage 示例写 `database/creds/my-role` |

这两份 MySQL/MariaDB 页面没有列出完整 policy capabilities 表；如果要给应用授权，至少本文能从官方示例确认应用申领动态凭据时读的是 `/creds` endpoint，但具体 policy 写法属于上层 Database engine API 范围。

---

## 10. 最容易踩的坑

1. **不要把四个 MySQL 插件实例混成一个名字**：官方列了 `mysql-database-plugin`、`mysql-aurora-database-plugin`、`mysql-rds-database-plugin`、`mysql-legacy-database-plugin` 四个实例，并说明差别是生成用户名长度；本文不能仅凭这两份原文替生产环境给出完整选型规则。

2. **要轮转 root，就别把 `connection_url` 写死成明文账号密码**：API 页说 `connection_url` 支持 `{{field_name}}` 模板，并且 root credential rotation 需要模板化 connection URL。

3. **x509 参数传的是内容，不是文件路径**：官方明确说 `tls_certificate_key` 与 `tls_ca` 对应 MySQL SSL 选项，但 Vault 参数是文件内容，不是文件名。

4. **带反引号的 wildcard grant 不要直接贴进 shell**：MySQL 要求通配部分放进反引号，而 shell 会解释反引号，所以官方建议把 creation statement base64 后再传给 Vault。

5. **MySQL 5.6 的 root rotation 语法不一样**：MySQL 默认 root rotation 使用 MySQL 5.7+ 的 `ALTER USER`；MySQL 5.6 要配置 `root_rotation_statements="SET PASSWORD = PASSWORD('{{password}}')"`。

6. **CloudSQL IAM 的连接协议不是 `tcp`**：官方注记写明 Google Cloud IAM 使用 `cloudsql-mysql` 协议，而不是 `tcp`。

7. **Static Roles 是支持项，但不是这两页的展开重点**：官方在开头和能力表确认 MySQL/MariaDB 插件支持 Static Roles；但本页 API 的 MySQL 专属参数只展开连接配置和 dynamic role statements，所以本文只记录“支持”这个事实。

---

## 11. 与其它章节的关系

和 [3.14 PostgreSQL](/ch3-postgres) 一样，本节也挂在通用 `database/` 引擎下面；差异在于 `plugin_name`、连接串语法和 SQL 模板从 PostgreSQL 换成 MySQL/MariaDB。

和 [2.3 Lease](/ch2-lease) 的关系在本节 MySQL/MariaDB 原文中只体现为 Usage 输出包含 `lease_id`、`lease_duration` 和 `lease_renewable`；API 页另说明 `revocation_statements` 是撤销用户时执行的语句。关于 Lease 到期如何触发撤销、再如何调用这些语句的完整因果链，属于上层 Database engine / Lease 文档范围，不由这两份 MySQL/MariaDB 页面单独证明。

和未来的云身份章节相比，本节只把 CloudSQL IAM 的 MySQL 插件配置形状讲清：`auth_type="gcp_iam"`、`cloudsql-mysql` 协议、ADC 或 `service_account_json`、`use_private_ip` / `use_psc`。

---

## 参考文献

- [MySQL/MariaDB database secrets engine](https://developer.hashicorp.com/vault/docs/secrets/databases/mysql-maria)
- [MySQL/MariaDB database plugin HTTP API](https://developer.hashicorp.com/vault/api-docs/secret/databases/mysql-maria)
- [MySQL Connection Options](https://dev.mysql.com/doc/refman/8.0/en/connection-options.html)
- [Google Cloud Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc#how-to)

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-mysql"/>
