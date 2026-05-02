# 恭喜完成 MySQL/MariaDB 数据库机密引擎实验！

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| **Step 1** | `database/config/mysql-main` 使用 `mysql-database-plugin`、模板化 `connection_url` 和 root credential；`rotate-root` 后旧密码失效 |
| **Step 2 Dynamic** | `vault read database/creds/readonly` 在 MySQL 里现场 `CREATE USER`，返回的账号密码能实连查询，revoke 或 TTL 到期后 `DROP USER` |
| **Step 3 Wildcard** | `GRANT SELECT ON fooapp_%.*` 可以授权一组数据库；base64 creation statement 可以避开 shell 反引号问题 |
| **Step 4 API 参数** | 你核对了 MySQL 插件的连接参数、默认用户名模板、x509 参数、GCP IAM 命令形状和 MySQL 5.6 root rotation 差异 |

## Dynamic 凭据速记

```
应用读 database/creds/readonly
        │
        ▼
Vault 替换 {{name}} / {{password}}
        │
        ▼
MySQL 执行 CREATE USER + GRANT SELECT
        │
        ▼
应用拿 username/password/lease_id 使用数据库
        │
        ▼
Lease revoke 或过期后 DROP USER
```

## 三个最容易踩的坑

1. `connection_url` 要用 `{{username}}` / `{{password}}` 模板，root rotation 才能让 Vault 更新内部保存的新密码。
2. wildcard grant 里的反引号会被 shell 解释，CLI 场景用 base64 传 `creation_statements` 更稳。
3. x509 的 `tls_certificate_key` / `tls_ca` 在 Vault 参数里传文件内容，不是 MySQL 客户端那种“传文件名”。

**返回文档**：[3.15 MySQL/MariaDB 数据库机密引擎](/ch3-mysql)
