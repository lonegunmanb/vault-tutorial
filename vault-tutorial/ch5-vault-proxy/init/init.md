# 实验说明

本实验将启动一个本地 Vault dev server，并预置一个只允许读取 `secret/proxy/app` 的 AppRole。你将使用这个 AppRole 作为 Vault Proxy 的 Auto-auth 身份，通过 `127.0.0.1:8100` 这个本地 listener 代理 Vault API 请求。

实验开始时，Vault Server 已经运行在 `http://127.0.0.1:8200`，Proxy 还没有启动。请按步骤手动启动 Proxy，并观察配置、token、请求和日志之间的关系。
