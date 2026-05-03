# 实验：AWS 认证完整动手（用 LocalStack 模拟 AWS）

[4.3 章](/ch4-aws) 把 AWS 认证方法的两套机制（`iam` / `ec2`）、
authorization 模型、推断（inferencing）、mixing 限制、Client Nonce /
Role Tag / Deny List 等高级选项都梳理了一遍。本实验**用 LocalStack
（一个本地 AWS API 兼容服务）模拟 AWS**，把 `iam` 方法的完整闭环
**真正跑通**，再把 `ec2` 方法和运维端点的配置面演示一遍。

> 本实验感谢 [LocalStack](https://www.localstack.cloud/) 提供稳定、
> 易用的本地 AWS 模拟环境。它让我们能在本机真实调用 IAM / STS API，
> 不用连真实 AWS 账号，也能把 Vault AWS auth 的核心链路敲透。

- **Step 1**：启动 LocalStack，`vault auth enable aws`，把
  `config/client` 的 `iam_endpoint` / `sts_endpoint` 指向 LocalStack；
  设 `iam_server_id_header_value`
- **Step 2**：建一个 IAM user + `auth_type=iam` role，并**真正完成一次
  iam 登录**——`vault login -method=aws` 走完"客户端签名 → Vault 转发
  STS → LocalStack 返回身份 → Vault 签发 token"全链路
- **Step 3**：在 LocalStack 上多建一个 IAM user，用它的凭据登录被
  `bound_iam_principal_arn` 约束直接拒；再切到通配符 ARN 让它通过
- **Step 4**：建 `auth_type=ec2` role 演示 mixing 拦截 + 跑一遍
  `identity-accesslist` / `roletag-denylist` / `tidy` 这些运维端点

## 实验环境会预先

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 安装 awscli v2、Docker、jq
- 预拉 LocalStack 镜像（`localstack/localstack:3`）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN` 与 LocalStack 的默认 AWS 凭据
  （`AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test`）
- **不会**预先启动 LocalStack、不会预先 enable aws 认证、不会预创建
  任何 role——所有动作由你在 step 里手敲

## ℹ️ 关于 LocalStack 的真实度

LocalStack 实现了 AWS IAM / STS API 的本地兼容版本，对
`sts:GetCallerIdentity` 的 SigV4 验签和 IAM access key 到 principal
的映射足够真实——所以 Vault 的 iam 认证流程在本地能跑通。LocalStack
**不模拟 EC2 实例的 PKCS#7 instance identity document 签名**——所以
`ec2` 方法只能演示配置面与拒绝路径，不可能真正登录成功。
