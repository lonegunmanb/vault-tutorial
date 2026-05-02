# 第 4 步：API 参数速查 —— x509、GCP IAM 与用户名模板

本地容器已经跑通了 Dynamic Role、root rotation 和 wildcard grant。最后一步把官方 API 页里的 MySQL 专属参数做一次“读配置 + 看命令形状”的核对：x509 和 GCP IAM 需要证书或 CloudSQL 环境，所以这里只看形状，不在本地强行执行。

---

## 4.1 读当前连接配置

```bash
vault read database/config/mysql-main
```

重点看这些字段：

- `plugin_name=mysql-database-plugin`
- `connection_url={{username}}:{{password}}@tcp(127.0.0.1:3306)/`
- `allowed_roles=my-role,readonly,wildcard-role`
- `max_open_connections=5`
- `max_connection_lifetime=5s`

这些都对应官方 API 页的 Configure connection 参数。

## 4.2 再观察一次默认用户名长度

```bash
CRED=$(vault read -format=json database/creds/readonly)
USER=$(echo "$CRED" | jq -r .data.username)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "$USER"
echo "length=${#USER}"

vault lease revoke "$LEASE"
```

普通 `mysql-database-plugin` 默认模板会把动态用户名截到 32 个字符以内；Aurora/RDS/legacy 插件组默认模板截到 16 个字符。

## 4.3 x509 命令形状

下面这段只有在你真的准备好了 MySQL 客户端证书和 CA 文件时才执行；官方 API 页要求 `tls_certificate_key` 是私钥和证书合并后的 PEM 内容，`tls_ca` 是 CA 的 PEM 内容。

```bash
# 示例形状：不要在当前实验环境直接执行
vault write database/config/my-mysql-x509 \
  plugin_name="mysql-database-plugin" \
  allowed_roles="my-role" \
  connection_url="user:password@tcp(localhost:3306)/test" \
  tls_certificate_key=@/path/to/client.pem \
  tls_ca=@/path/to/client.ca
```

生产里还可以结合 `tls_server_name` 校验证书里的 SAN；`tls_skip_verify=true` 会关闭服务器证书校验，官方不建议生产使用。

## 4.4 GCP CloudSQL IAM 命令形状

GCP IAM 模式下，官方强调连接协议是 `cloudsql-mysql`，不是普通 `tcp`。ADC 方式长这样：

```bash
# 示例形状：需要真实 GCP/CloudSQL 环境
vault write database/config/my-mysql-cloudsql \
  plugin_name="mysql-database-plugin" \
  allowed_roles="my-role" \
  connection_url="user@cloudsql-mysql(project:region:instance)/mysql" \
  auth_type="gcp_iam" \
  use_private_ip="false" \
  use_psc="false"
```

如果你要直接传服务账号 JSON，官方示例是增加 `service_account_json="@my_credentials.json"`：

```bash
# 示例形状：需要真实服务账号 JSON
vault write database/config/my-mysql-cloudsql \
  plugin_name="mysql-database-plugin" \
  allowed_roles="my-role" \
  connection_url="user@cloudsql-mysql(project:region:instance)/mysql" \
  auth_type="gcp_iam" \
  use_private_ip="false" \
  use_psc="false" \
  service_account_json="@my_credentials.json"
```

GCP IAM role 示例里，官方还覆盖了 `revocation_statements`，让 Vault 撤销时执行 `DROP USER '{{name}}'@'%';`。

## 4.5 MySQL 5.6 root rotation 命令形状

当前实验用 MySQL 8，不需要这个旧语法；但如果你管理的是 MySQL 5.6，官方示例要求配置 `root_rotation_statements`：

```bash
# 示例形状：仅 MySQL 5.6 场景需要
vault write database/config/my-mysql-56 \
  plugin_name="mysql-database-plugin" \
  connection_url="{{username}}:{{password}}@tcp(127.0.0.1:3306)/" \
  root_rotation_statements="SET PASSWORD = PASSWORD('{{password}}')" \
  allowed_roles="my-role" \
  username="root" \
  password="mysql"
```

---

## ✅ 验收

- [ ] 能读到 `mysql-main` 的连接配置
- [ ] 再次申领的 MySQL 动态用户名长度不超过 32
- [ ] 能说清 x509 的 `tls_certificate_key` / `tls_ca` 传的是文件内容
- [ ] 能说清 GCP IAM 用 `cloudsql-mysql` 协议，不是 `tcp`
- [ ] 能说清 MySQL 5.6 root rotation 为什么要 `SET PASSWORD`
