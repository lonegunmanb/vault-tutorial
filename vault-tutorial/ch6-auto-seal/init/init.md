# 实验说明

本实验承接 6.3 节正文：学员此时已具备使用一份 `vault.hcl` 启动非 dev 模式 raft 单节点 Vault 的能力（6.1 节），并已掌握 listener TLS 强化的基本操作（6.2 节）。本实验在该骨架之上，额外引入一个 `seal "awskms"` 块，把 Vault 的根密钥保护从默认的 Shamir 模式切换为 AWS KMS auto-unseal。

由于本课程严格限定在零真实云成本的条件下完成全部动手部分，本实验**采用 LocalStack 在本地模拟 AWS KMS 服务**——LocalStack 实现了 AWS KMS API 的本地兼容版本，对 `kms:Encrypt` / `kms:Decrypt` / `kms:DescribeKey` 这三个 Vault 在解封时实际调用的 API 足够真实，因此 Vault 的 auto-unseal 流程在本地能跑通。

> 本实验感谢 [LocalStack](https://www.localstack.cloud/) 提供稳定、易用的本地 AWS 模拟环境。它让学员能在不连接真实 AWS 账号、不产生任何云费用的前提下，把"Vault → AWS KMS → 解封根密钥"这条链路真正打通。

实验开始时，环境已完成下列准备：

- 已安装 `vault`、`jq`、`openssl`、`curl`、`docker`、`awscli` v2、`awslocal` 与 `socat`（后者在 Step 2 用作 KMS 流量的可宕机中转层）；
- 已预拉 `localstack/localstack:3` 容器镜像；
- 已在 `/root/vault.hcl` 中预置一份**仅含 `storage` / `listener` 的最小配置**——`seal` 块由学员在 Step 2 自行追加；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 与 `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` / `AWS_DEFAULT_REGION=us-east-1` 写入 `/etc/profile.d/`，登录 shell 自动加载。

LocalStack 容器、KMS 流量代理、Vault 进程**均尚未启动**；请依照后续步骤逐一手动启动。
