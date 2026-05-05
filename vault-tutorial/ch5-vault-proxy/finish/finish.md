# 恭喜完成实验！

你已经完成了 `vault proxy` 的基础实验：从配置文件出发，启动 Proxy，观察 Auto-auth token 写入 sink，并通过本地 listener 代理 Vault API 请求。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| 配置文件阅读 | `vault`、`auto_auth`、`api_proxy`、`cache`、`listener` 共同定义 Proxy 的运行方式 |
| Auto-auth | Proxy 可以用 AppRole 自动登录 Vault，并把 token 写入 file sink |
| API proxy | 应用可以请求本地 Proxy listener，而不是直接请求 Vault server |
| 强制 token 模式 | `use_auto_auth_token = "force"` 会忽略请求自带 token，使用 Proxy 的 Auto-auth token |
| 排错 | 412 表示 Proxy listener 拒绝，403 表示 Vault policy 拒绝 |

## 关键心智模型

```text
应用请求 -> Proxy listener -> Auto-auth token / cache / API proxy -> Vault server
```

后续学习 Vault Agent、Kubernetes 集成或真实应用接入时，可以继续沿用这个分层模型：应用不直接处理所有 Vault 细节，而是把认证、续期、转发、缓存等职责交给靠近应用运行的专用组件。
