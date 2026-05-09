# 恭喜完成实验！

你已经完成了 Vault Proxy 的应用接入实验：启动了两种 `use_auto_auth_token` 模式的 Proxy，观察了请求自带 token 与 Auto-auth token 的优先级差异，调用了 cache-clear 管理 API，并阅读了 Kubernetes persistent cache 的配置模型。

## 本实验的核心收获

| 阶段 | 你亲手验证或阅读的事实 |
| :--- | :--- |
| `true` 模式 | 请求没有 token 时使用 Auto-auth token；请求自带 token 时由请求 token 决定最终身份 |
| `force` 模式 | 请求自带 token 会被忽略，最终身份固定为 Proxy Auto-auth token |
| 请求头保护 | 缺少 `X-Vault-Request: true` 时，Proxy listener 可以在请求到达 Vault 前返回 412 |
| cache-clear | `/proxy/v1/cache-clear` 是 Proxy 的 cache 管理 API，返回 200 不代表所有 KV 请求都会缓存 |
| persistent cache | Kubernetes persistent cache 用于同一 Pod 内 init 与 sidecar Proxy 的 tokens 和 leases 交接 |

## 一张图总结本节

```text
应用请求
  |
  v
Proxy listener
  |-- require_request_header 检查
  |-- use_auto_auth_token: false / true / force
  |-- cache: token / leased secret / static secret 边界
  v
Vault server
  |
  v
根据最终 token 的 policy 授权
```

## 回到正文

回到 [7.3 章正文](/ch7-vault-proxy) 后，建议重点复查 §3 的 Auto-auth token 模式、§4 至 §5 的 cache 边界、§6 的 Kubernetes persistent cache 使用边界。这三处决定了 Proxy 在真实应用接入中的身份边界和运行风险。