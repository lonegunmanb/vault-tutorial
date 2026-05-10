# 实验说明

本实验会在 Killercoda 提供的 kubeadm 单节点 Kubernetes 环境中完成一次完整的 Vault Agent Injector 工作流。后台脚本只安装 Vault CLI、Helm 等基础工具，并准备后续会用到的 YAML；真正的演示组件安装会在第一步由你执行。

第一步会完成以下工作：

1. 使用 Helm 安装 Vault dev server 与 Vault Agent Injector。
2. 创建 `demo` namespace、`webapp` ServiceAccount，以及初始化 Job 使用的临时 ServiceAccount。
3. 授权 Vault server ServiceAccount 调用 Kubernetes TokenReview API。
4. 运行 `/root/configure-vault-agent-injector.sh`，通过 Kubernetes Job 在 Vault 中配置 `auth/kubernetes`、Vault role `webapp` 与 KV v2 机密 `secret/injector/web`。

后台已准备三份 YAML：`/root/baseline.yaml`、`/root/injector-demo.yaml`、`/root/init-only-job.yaml`。

本实验中会反复看到几个容器名：`app` 是 Deployment 里的示例业务容器；`worker` 是 init-only Job 里的示例任务容器；`vault-agent-init` 是 Injector 注入的 init container，负责在业务容器启动前登录 Vault 并把机密预先渲染到 `/vault/secrets`；`vault-agent` 是默认注入模式下的运行期 sidecar，负责在 Pod 运行期间继续维护认证和模板渲染。使用 `agent-pre-populate-only` 的 Job 只会有 `vault-agent-init`，不会有运行期 `vault-agent`。

完成第一步后，Vault 可通过本机端口转发访问：`VAULT_ADDR=http://127.0.0.1:8200`，root token 为 `root`。如果 Vault CLI 提示连接被拒绝，运行 `ensure-vault-port-forward` 即可重新建立端口转发。你将先观察没有注解的 Pod 不会被改写，再给 Deployment 加上 Injector annotations，最后用 init-only Job 对比 sidecar 与一次性预填充的生命周期差异。