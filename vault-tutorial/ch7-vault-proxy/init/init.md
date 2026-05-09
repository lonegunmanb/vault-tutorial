# 实验说明

本实验将启动一个本地 Vault dev server，并预置两类 Vault token：一类是 Vault Proxy 通过 AppRole Auto-auth 得到的最小权限 token，允许读取 `secret/proxy73/app`；另一类是学员手中用于对照的低权限 token，不能读取这条机密。

你将依次启动两个 Proxy：第一个使用 `use_auto_auth_token = true`，第二个使用 `use_auto_auth_token = "force"`。通过对比这两个 listener 的行为，可以清楚看到“请求自带 token 是否会覆盖 Proxy Auto-auth token”。

实验最后会阅读一份 Kubernetes persistent cache 配置模型。当前实验使用普通 Ubuntu 后端，不直接部署 Kubernetes；该步骤的目标是让你理解官方文档中 initialization Proxy container、sidecar Vault Proxy container 与 memory volume 的交接关系。