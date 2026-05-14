# 实验说明

本实验配套 [9.6 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-identity-broker-postgres.html)：学员此时已经在概念层理解了 Vault 作为 identity broker 的三阶段事务模型（Phase 1 验证身份、Phase 2 内部 ACL 判定、Phase 3 现场签发外部凭据），以及"换上游认证方、不换下游凭据生成"是 brokering 范式的核心抽象。本实验把这套抽象在终端里跑两遍：

1. **第一步（AWS IAM → PostgreSQL）**：用 LocalStack 在本机模拟 AWS 的 IAM/STS 服务，启用 Vault `aws` auth method、把 `sts_endpoint`/`iam_endpoint` 指向 LocalStack；启用 `database` 引擎并把本地 PostgreSQL 接进 Vault；创建一条 `auth/aws/role/app-aws`，绑定到刚建好的 IAM user 的 ARN；用 IAM user 的 access key `vault login -method=aws` 拿到 Vault token，调 `database/creds/readonly` 申领临时 PostgreSQL 凭据，用这对凭据 `psql` 直连数据库执行业务 SQL；最后 `vault lease revoke` 后回到 PG 端验证临时账号已被 Vault 主动 DROP 干净。
2. **第二步（K8s ServiceAccount → 同一份 PostgreSQL 动态凭据）**：在 Killercoda 预置的单节点 Kubernetes 集群里启用 Vault `kubernetes` auth method、配置 reviewer JWT；创建 namespace `demo` 与 ServiceAccount `app-k8s`；创建一条 `auth/kubernetes/role/app-k8s` 绑定到该 SA。整个第二步**不会改动** `database/config/postgres-broker` 与 `database/roles/readonly` —— 它们是第一步留下来的、**完全相同的下游配置**。在 K8s 里 `kubectl run` 一个 Pod，把 vault CLI 安装进去，进 Pod 后用 `kubectl create token` 取得短期 JWT、`vault write auth/kubernetes/login` 换得 Vault token、再调**完全相同的** `database/creds/readonly` 申领临时凭据；最终在 Pod 里用临时凭据连进同一个 PostgreSQL 实例的同一张表。

为完全规避真实云成本，整个实验都在单台 Killercoda Kubernetes 主机上完成：

- 已安装 `vault`（1.19.2）、`jq`、`curl`、`postgresql-client`、AWS CLI v2 与 `awslocal`；
- 已用 docker 启动了 `learn-postgres`（postgres:16，superuser=root/rootpassword，监听 `5432`）与 `localstack`（端口 `4566`）两个本机容器；
- PostgreSQL 内已预置 `vaultadmin`（CREATEROLE、`demo` schema 上有 GRANT OPTION）作为 Vault 的 root；以及 `demo.kv` 表两条业务数据；
- Vault 以 dev 模式运行在 `127.0.0.1:8200`，root token 固定为 `root`；
- Killercoda 预置的单节点 kubeadm 集群已就绪，`KUBECONFIG` 已写入 `/root/.bashrc`，可直接 `kubectl` 操作。

> **本实验的所有"AWS"调用都打在 LocalStack 上**，账号 ID 固定为 `000000000000`、签出来的临时凭据有效期由 LocalStack 决定。LocalStack 仅支持 Vault aws auth 的 `iam` 模式（不支持 `ec2`），与 4.3 章实验的设计一致；生产环境对接真实 AWS 时无需 `sts_endpoint`/`iam_endpoint` 覆盖。

> 本实验全程使用明文 HTTP 与本机 PG，目的是让 `curl`、`vault`、`psql` 命令的输出干净易读、便于直接观察响应；生产环境请按 [9.1 节](https://lonegunmanb.github.io/vault-tutorial/ch9-production-hardening.html) 所述启用端到端 TLS。
