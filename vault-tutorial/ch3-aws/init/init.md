# 实验：AWS 机密引擎动态 IAM 凭据全流程

3.3 章节梳理了 AWS 机密引擎"动态铸凭据"的核心机制：

- **`config/root` 是种子 key**——Vault 用这对管理员凭据去 AWS 铸临时
  凭据
- **三种 `credential_type`**：`iam_user`（建真 User）、`assumed_role`
  （调 STS AssumeRole）、`federation_token`（调 STS GetFederationToken）
- **路径分离**：取 `iam_user` / `federation_token` 走 `aws/creds/<role>`，
  取 `assumed_role` 走 `aws/sts/<role>`
- **Lease 即生命周期**：`vault lease revoke` 真的会去 AWS 调
  `DeleteUser` / 让 Session 失效

本实验让你不用真实 AWS 账号就能把这些行为亲手跑一遍——我们用
[**MiniStack**](https://ministack.org/)（MIT 协议、单端口 4566 的本地
AWS API 模拟器）当 AWS 后端。

实验环境已自动准备好：

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN`，所有终端都能直接 `vault`
- 安装 Docker（用于跑 MiniStack 容器）、AWS CLI（用于直连 MiniStack
  验证 IAM 状态）、jq
- 持久化 `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test`
  （MiniStack 的 root 凭据）、`AWS_DEFAULT_REGION=us-east-1`、
  `AWS_PAGER=""`（关掉 less 分页，避免终端被卡住）

不会预启 MiniStack 容器——Step 1 第一步就是亲手把它跑起来，让你看清
"Vault 调的 AWS API 终点其实是一个跑在 4566 端口的普通 HTTP 服务"。

> **federation_token 不在本实验范围**：MiniStack 没实现
> `sts:GetFederationToken`，会直接返回 `InvalidAction`。本实验聚焦
> `iam_user` 与 `assumed_role` 这两条覆盖了文档 90% 实战内容的路径。
