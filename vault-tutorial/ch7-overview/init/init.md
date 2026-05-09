# 实验说明

本实验将启动一个本地 Vault dev server，并预置一条统一的 KV 机密 `secret/seven/app`，以及一个最小权限 AppRole `seven-app`。你将依次用三种方式从 Vault 取出同一条机密：

1. 用 `vault kv get` 直接读取（学员手中已有 root token）。
2. 用 Vault Agent 启动一个模板渲染流程，把同一条机密以文件形式落地。
3. 用 Vault Proxy 启动一个本地代理 listener，让一份没有 token 的 CLI 请求通过 Proxy 代办认证后取得机密。

实验开始时，Vault Server 已经运行在 `http://127.0.0.1:8200`；Agent 与 Proxy 均未启动，配置文件已经写好放在 `/root/` 目录下，等待你按步骤手动启动。
