# 实验说明

本实验配套 [6.5 节正文](/ch6-other-storage)。学员在 6.4 节已经具备 Integrated Storage（Raft）的实操能力；本实验目的不是再练一遍生产推荐方案，而是让学员**亲眼看到** filesystem / in-memory / postgresql 这三种"非 raft"后端在持久化语义、HA 能力与运维步骤上的差异，以便在以后阅读他人配置或排查存量集群时能快速识别。

由于本课程严格限定零真实云成本，**DynamoDB、S3、Consul 三种后端不在本实验范围内**——它们都依赖外部托管服务或额外的 Consul 集群，把它们硬塞进单机 Killercoda 主机会模糊本实验的教学焦点。学员可以在 6.5 节正文中阅读对应的参数与定位说明。

实验开始时已完成下列准备：

- 已安装 `vault`（1.19.2）与 `psql` 客户端；
- 已为三个步骤分别预置 `vault.hcl`：
  - `/root/vault-file.hcl`：`storage "file" { path = "/opt/vault/file-data" }`；
  - `/root/vault-inmem.hcl`：`storage "inmem" {}`；
  - `/root/vault-pg.hcl`：`storage "postgresql" { connection_url = "postgres://vault:vaultpw@127.0.0.1:5432/vault?sslmode=disable" }`；
- 已为 filesystem 后端预创建数据目录 `/opt/vault/file-data`（权限 700）；
- 已写好 PostgreSQL 后端的官方 schema SQL：`/root/vault-pg-schema.sql`；
- 已生成两个便捷脚本：
  - `/root/start-vault.sh <file|inmem|pg>`：先 kill 现有 vault 进程，再以指定后端重启；日志在 `/var/log/vault-${mode}.log`；
  - `/root/start-postgres.sh`：在 Step 3 才执行，使用 docker 拉起一个本地 PostgreSQL 实例供 Vault 后端使用；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/`，登录 shell 自动加载。

> 本实验全程使用明文 HTTP（`tls_disable = true`），目的是把学员注意力集中在 storage 块的差异上，而非 listener TLS。生产环境必须按 6.2 节的基线启用 TLS。
