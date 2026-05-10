# 实验说明

本实验使用 Killercoda 提供的 Kubernetes 单节点环境。后台脚本只安装 Vault CLI、Helm 与常用命令行工具；Secrets Store CSI driver、Vault dev server、Vault Secrets Store CSI provider，以及实验 namespace / ServiceAccount 都会在第一步由你执行安装与创建。

第一步会运行 `/root/configure-vault-csi.sh`，通过 Kubernetes Job 在 Vault 中配置 Kubernetes auth method、KV v2 机密 `secret/csi/app`、policy 与 Vault role `csi-app`，并生成后续步骤使用的 `/root/csi-file-mount.yaml`、`/root/csi-bad-sa.yaml`、`/root/csi-env-sync.yaml` 与 `/root/csi-env-app.yaml`。

如果你第一次接触 Kubernetes CSI 或 Helm，先不要急着记住所有对象名。本实验只想证明一件事：**Pod 可以不直接调用 Vault API，而是通过 Kubernetes 的 CSI volume 机制，让平台组件把 Vault 里的值放进 Pod 能读取的位置。**

把四个步骤连起来看，会更清楚：

| 步骤 | 你在做什么 | 这一页想证明什么 |
| --- | --- | --- |
| Step 1 | 安装平台组件，创建实验身份，准备 Vault 端数据 | 先把“厨房”和“食材”准备好，后面 Pod 才能点单取机密 |
| Step 2 | 创建 `SecretProviderClass` 和一个 Deployment | Pod 可以把 Vault 机密挂载成容器里的普通文件 |
| Step 3 | 先让 Pod 使用错误的 ServiceAccount，再修回正确身份 | Vault role 会检查 Pod 身份；修回 `csi-demo/app` 后挂载会恢复成功 |
| Step 4 | 使用 `secretObjects` 同步 Kubernetes Secret，再注入环境变量 | 如果应用只能读环境变量，可以先同步成 K8s Secret，再用 `secretKeyRef` 注入 |

本实验里几个名字的含义如下：

| 名词 | 在本实验里是什么意思 |
| --- | --- |
| `secret/csi/app` | Vault 里的 KV v2 路径，里面有 `username`、`password`、`api_key` |
| `csi-demo` | 应用所在的 Kubernetes namespace |
| `app` | `csi-demo` namespace 下的 Kubernetes ServiceAccount，也就是实验应用 Pod 的身份 |
| `csi-app` | Vault role 名称，只允许 `csi-demo/app` 这个 Pod 身份登录 Vault |
| `SecretProviderClass` | Kubernetes 里的“取密配置单”，写明 provider 是 `vault`、用哪个 Vault role、读哪些 Vault 字段、写成哪些文件 |
| `objectName` | CSI 挂载目录里的文件名，也是 `secretObjects` 引用对象时使用的别名 |
| `secretPath` | Vault API 读取路径，例如 `secret/data/csi/app` |
| `secretKey` | 从 Vault 响应里取哪个字段，例如 `username` 或 `password` |
| Kubernetes Secret | Kubernetes 自己的 Secret 对象，和 Vault 里的 secret 不是同一个东西 |

你将依次完成四个任务：

1. 安装 Secrets Store CSI driver、Vault provider，创建实验身份，并检查 `SecretProviderClass` CRD。
2. 创建 `SecretProviderClass` 与 Deployment，把 Vault 机密挂载到 `/mnt/secrets-store`。
3. 使用未授权 ServiceAccount 触发挂载失败，再修回正确身份，观察 Vault role 与 Pod 身份的边界。
4. 使用 `secretObjects` 把同一份数据同步为 Kubernetes Secret，并通过 `secretKeyRef` 注入环境变量。

实验使用 KV v2 静态机密来聚焦 CSI 挂载链路。动态数据库凭据、证书 lease 与轮转策略会在后续数据库、PKI 与 VSO 章节继续展开。