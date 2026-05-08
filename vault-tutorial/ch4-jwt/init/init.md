# JWT/OIDC 认证实验

本实验将在 Killercoda 的 kubeadm 单节点 Kubernetes 环境中运行 Vault Dev Server，并使用 Kubernetes ServiceAccount Token 体验 `auth/jwt` 的签名验证流程。

你将完成四件事：

1. 创建 `demo/jwt-app` ServiceAccount，生成短生命期 token，并解码观察 `iss`、`sub`、`aud`、`exp` 等 claim。
2. 把 Kubernetes 控制平面上的 ServiceAccount 签名公钥配置到 Vault `auth/jwt/config`。
3. 创建 JWT role，验证正确 token 可以登录，错误 audience 或错误 subject 会被拒绝。
4. 删除 ServiceAccount 后再次登录，观察 JWT auth 不调用 TokenReview 时的撤销边界。

本实验是 [4.4 Kubernetes 认证](/ch4-k8s) 的对照实验：`auth/kubernetes` 依赖 TokenReview，`auth/jwt` 依赖签名验证与 claim 约束。