# 实验说明

本实验配套 [6.5 节正文](https://lonegunmanb.github.io/vault-tutorial/ch6-other-storage.html)。学员在 6.4 节已经具备 Integrated Storage（Raft）的实操能力；本实验目的不是再练一遍生产推荐方案，而是让学员**亲眼看到** filesystem / in-memory / postgresql / s3 / dynamodb 这五种"非 raft"后端在持久化语义、HA 能力与运维步骤上的差异，以便在以后阅读他人配置或排查存量集群时能快速识别。

由于本课程严格限定零真实云成本，**S3 与 DynamoDB 通过本地 [LocalStack](https://www.localstack.cloud/)（本地 AWS API 兼容服务、监听 :4566）模拟**——配置思路与第 3 章 AWS 机密引擎实验、以及 [4.4 节 AWS 认证](/ch4-aws) 实验完全一致：Vault 与 AWS 之间是普通 HTTP API 调用，把 endpoint 指向本地 LocalStack 即可在零真实云的前提下跑通 S3 / DynamoDB 后端。Consul 后端则因依赖额外的 Consul 集群、与本节聚焦点无关，仍不在本实验范围内（学员可在 6.5 节正文中阅读对应参数与定位说明）。

> 本实验感谢 [LocalStack](https://www.localstack.cloud/) 提供稳定、易用的本地 AWS 模拟环境，让我们能在本机真实调用 S3 / DynamoDB API 验证 Vault 外部存储后端的运行路径。

实验开始时已完成下列准备：

- 已安装 `vault`（1.19.2）、`jq`、`psql` 客户端、`docker`、`aws` CLI v2 与 `awslocal` 包装器；
- 已为五个步骤分别预置 `vault.hcl`：
  - `/root/vault-file.hcl`：`storage "file" { path = "/opt/vault/file-data" }`；
  - `/root/vault-inmem.hcl`：`storage "inmem" {}`；
  - `/root/vault-pg.hcl`：`storage "postgresql" { connection_url = "postgres://vault:vaultpw@127.0.0.1:5432/vault?sslmode=disable" }`；
  - `/root/vault-s3.hcl`：`storage "s3" { endpoint = "http://127.0.0.1:4566", bucket = "vault-data", s3_force_path_style = "true", ... }`；
  - `/root/vault-dynamodb.hcl`：`storage "dynamodb" { endpoint = "http://127.0.0.1:4566", ha_enabled = "true", table = "vault-data", ... }`；
- 已为 filesystem 后端预创建数据目录 `/opt/vault/file-data`（权限 700）；
- 已写好 PostgreSQL 后端的官方 schema SQL：`/root/vault-pg-schema.sql`；
- 已生成三个便捷脚本：
  - `/root/start-vault.sh <file|inmem|pg|s3|dynamodb>`：先 kill 现有 vault 进程，再以指定后端重启；日志在 `/var/log/vault-${mode}.log`；
  - `/root/start-postgres.sh`：在 Step 3 才执行，使用 docker 拉起一个本地 PostgreSQL 实例；
  - `/root/start-localstack.sh`：在 Step 4 / Step 5 才执行，使用 docker 拉起一个本地 LocalStack 实例（镜像 `localstack/localstack:3`，暴露 :4566 端口）；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 与 `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` / `AWS_DEFAULT_REGION=us-east-1` 写入 `/etc/profile.d/`，登录 shell 自动加载。

> 本实验全程使用明文 HTTP（`tls_disable = true`），目的是把学员注意力集中在 storage 块的差异上，而非 listener TLS。生产环境必须按 6.2 节的基线启用 TLS。
