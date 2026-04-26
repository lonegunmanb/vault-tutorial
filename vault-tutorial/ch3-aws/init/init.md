# 实验：AWS 机密引擎动态 IAM 凭据全流程

3.3 章节梳理了 AWS 机密引擎"动态铸凭据"的核心机制：

- **`config/root` 是种子 key**——Vault 用这对管理员凭据去 AWS 铸临时
  凭据
- **三种 `credential_type`**：`iam_user`（建真 User）、`assumed_role`
  （调 STS AssumeRole）、`federation_token`（调 STS GetFederationToken）
  ——还有一种 `session_token`（调 `sts:GetSessionToken`）官方文档把它
  归为"权限完全继承 root key"的特殊类型，本实验不演示
- **路径分离**：取 `iam_user` 走 `aws/creds/<role>`；取所有 STS 类
  （`assumed_role` / `federation_token` / `session_token`）都走
  `aws/sts/<role>`
- **Lease 即生命周期**：`vault lease revoke` 真的会去 AWS 调
  `DeleteUser` / 让 Session 失效

本实验让你不用真实 AWS 账号就能把这些行为亲手跑一遍——我们用
[**MiniStack**](https://ministack.org/) 当 AWS 后端。

## 关于 MiniStack

[MiniStack](https://ministack.org/)（[GitHub](https://github.com/ministackorg/ministack)）
是一个**单端口 4566 的本地 AWS API 模拟器**，由社区在 2026 年 LocalStack
把核心服务挪到付费版后推出，定位是 LocalStack Community 的"免费、无遥
测、无 API key、无账号"替代。它在一个 ~270MB 的 Docker 镜像里实现了
45+ AWS 服务（包括本实验需要的 IAM / STS / S3），冷启动 ~2 秒、空闲
时仅占 ~30MB 内存——非常适合 Killercoda 这种轻量交互环境。

特别要点出的是：**MiniStack 用 MIT 协议开源**——任何使用、修改、
fork、嵌入到商业课程都不需要付费、不需要审批，这也是本课程能直接把它
塞进 Killercoda 实验里随学员任意运行的根本原因。

> 致谢：感谢 MiniStack 的作者与维护者把 AWS 本地模拟器重新带回开源世
> 界。本实验的全部 IAM / STS 调用都打到他们的镜像上完成。如果你觉得
> 这套体验顺手，请去他们的
> [GitHub 仓库](https://github.com/ministackorg/ministack)
> 点个 star 支持一下。

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
