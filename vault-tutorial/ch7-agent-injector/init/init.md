# 实验说明

本实验会在 Killercoda 提供的 kubeadm 单节点 Kubernetes 环境中完成一次完整的 Vault Agent Injector 工作流。初始化脚本已经预置以下内容：

1. 使用 Helm 安装 Vault dev server 与 Vault Agent Injector。
2. 在 Vault 中启用并配置 `auth/kubernetes`。
3. 创建 `demo/webapp` ServiceAccount，并把它绑定到 Vault role `webapp`。
4. 写入 KV v2 机密 `secret/injector/web`。
5. 准备三份 YAML：`/root/baseline.yaml`、`/root/injector-demo.yaml`、`/root/init-only-job.yaml`。

实验开始时，Vault 可通过本机端口转发访问：`VAULT_ADDR=http://127.0.0.1:8200`，root token 为 `root`。你将先观察没有注解的 Pod 不会被改写，再给 Deployment 加上 Injector annotations，最后用 init-only Job 对比 sidecar 与一次性预填充的生命周期差异。