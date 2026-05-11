# 实验说明

本实验配套 [9.2 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-eaas-transit.html)：学员此时已经在概念层理解了「加密即服务（Encryption as a Service, 简称 EaaS）」的核心思想——**应用持密文 / Vault 持钥匙**，业务数据库里存放的全部是 `vault:v<N>:...` 形式的不透明密文，离开了 Vault 任何人都无法把它还原成明文。本实验把这套思想落到一个**与 HashiCorp 官方 Spring Cloud 演示**（[hashicorp-education/learn-vault-spring-cloud](https://github.com/hashicorp-education/learn-vault-spring-cloud) 的 `vault-transit/` 子项目）**外部行为完全一致**的最小 Go Web 应用上：相同的 `/payments` 端点语义、相同的 `cc_info` 字段名、相同的 PostgreSQL 表结构（来自官方 [`schema.sql`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/resources/schema.sql)）、相同的 Vault 密钥名 `payments`，区别只在于实现语言换成了 Go + [Gin](https://github.com/gin-gonic/gin)。

实验分三步：

1. **第一步**：检查后台已经替你准备好的 Vault 与 Postgres；浏览一份预先准备好的 Gin 应用源码（不到 280 行 Go 代码）；启动它；用 `curl` 写入一笔支付记录；用 `psql` 直接打开 PostgreSQL 的 `payments` 表，**亲眼看到** 落库的 `cc_info` 字段是 `vault:v1:...` 形式的密文，而经由应用 `GET /payments` 返回的同一字段是明文。
2. **第二步**：执行密钥轮转，写入一笔新记录验证它被自动用新版本（`v2`）密钥加密；调用应用的 `/admin/rewrap` 端点，把所有旧版本密文升级到新版本——验证这一过程**全程不接触明文**。
3. **第三步**：换用一个被严格策略限制的『应用专用』Token 重启应用，吊销该 Token，再次请求读取接口——观察应用立即收到 Vault 返回的 `403 permission denied`、整条业务读链路被切断的现象，从而验证「Vault 是这套数据的最终单点开关」。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成：

- 已安装 `vault`（1.19.2，dev 模式后台运行）、`golang-go`（来自 Ubuntu 24.04 apt 仓库的 1.22）、`jq`、`curl`、`postgresql-client`；
- 已写入 `VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`；并已写入 `PGHOST` / `PGUSER` / `PGDATABASE` / `PGPASSWORD` / `DATABASE_URL` 等便捷连接环境变量；
- 已启用 `transit/` 引擎、创建 `transit/keys/payments` 密钥、把 `deletion_allowed` 调成 `true`（与官方 docker-compose.yaml 中 `vault-configure` 容器的初始化行为完全一致）；
- 已用 `docker run --rm postgres:16` 起一个名为 `learn-postgres` 的 PostgreSQL 容器，监听本机 `127.0.0.1:5432`，与官方仓库一致的口令 `postgres-admin-password`、库名 `payments`；建表 DDL 与官方 [`schema.sql`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/resources/schema.sql) 一一对应；
- 已在 `/root/eaas-app/` 准备好 `app.go`（Gin 应用源码）与 `go.mod`（依赖清单），并已预先 `go mod tidy` 与 `go build` 出二进制 `/root/eaas-app/app`，避免课堂上等待网络下载。

> 本实验全程使用明文 HTTP（应用监听 `:8080`、Vault 监听 `:8200`），目的是让 `curl` 输出干净易读、便于直接观察请求与响应；生产环境应当按 [6.2 节](/ch6-listener-tls)、[9.1 节](/ch9-production-hardening) 所述启用端到端 TLS。同样，dev 模式 Vault 用 `root` Token、把数据保存在内存里，绝不能用于任何真实业务。
