# 实验：Kubernetes 认证完整动手

[4.4 章](/ch4-k8s) 讲的是 Kubernetes 认证方法：Pod 或其他 Kubernetes 工作负载把自己的 ServiceAccount JWT 交给 Vault，Vault 调用 Kubernetes TokenReview API 验证该 JWT 是否仍然有效，再根据 Vault role 的约束签发 Vault token。

本实验运行在 Killercoda 的 `kubernetes-kubeadm-1node` 环境中；该环境提供一个 kubeadm 单节点集群，并且适合直接运行 Kubernetes 场景步骤。

实验步骤使用 `kubectl create token` 生成 TokenRequest 风格的短生命期 ServiceAccount token；该命令要求较新的 Kubernetes / kubectl 版本（建议 `kubectl >= 1.24`），Killercoda 当前 kubeadm 环境通常满足这一条件。

## 实验会完成

- **Step 1**：创建 reviewer ServiceAccount，授予 `system:auth-delegator`，启用 `auth/kubernetes` 并写入 `auth/kubernetes/config`。
- **Step 2**：创建 `demo/myapp` ServiceAccount，给它签发短生命期 JWT，使用 `auth/kubernetes/login` 换取 Vault token。
- **Step 3**：验证 ServiceAccount 名称、namespace selector 与 audience 对登录结果的影响。
- **Step 4**：启用 ServiceAccount 注解到 Vault alias metadata 的映射，并用 templated policy 让 Kubernetes 注解决定可读的 KV 路径。

## 实验环境会预先

- 安装 Vault 并以 Dev 模式启动，root token 固定为 `root`。
- 等待 Killercoda 预置的 Kubernetes 单节点集群就绪，并持久化 `KUBECONFIG`。
- 安装 `jq` 与 `curl`，便于解析 Vault 登录响应与 Kubernetes token。
- 不会预先创建 Kubernetes auth 配置、Vault role、ServiceAccount 或 policy；这些动作都将在步骤中手动完成。

## 关于实验安全边界

Killercoda 环境是临时且隔离的，文档也提醒不要在场景中使用生产密钥；本实验只使用临时 ServiceAccount token、Dev 模式 Vault root token 与教学用 KV 数据。
