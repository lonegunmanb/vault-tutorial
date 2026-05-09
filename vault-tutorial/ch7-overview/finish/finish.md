# 恭喜完成实验！

你已经在同一台 Vault dev server 上，分别用 `vault kv get`、Vault Agent 模板渲染、Vault Proxy 代理三种方式取出了同一条 KV 机密，并把三者在认证主体、令牌存放位置、机密呈现形式与缓存归属上的差异整理成一张三栏对照表。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| 方式一 CLI 直读 | 应用必须自己持有 token，令牌通过环境变量传入 |
| 方式二 Agent 渲染 | 同一条机密可以被以「本地文件」形态交付给应用 |
| 方式三 Proxy 代理 | 应用即便不带 token，也能通过 Proxy 强制使用 Auto-auth token 完成请求 |
| 三栏对照表 | 三种方式的差异落在「谁认证、token 放哪、机密形式」三个维度上 |

## 关键心智模型

```text
应用 -> [自己 / Agent / Proxy / K8s 控制器] -> Vault server
            └─ 三种部署形态决定 token 与机密的归属
```

后续学习 Vault Agent 的模板渲染、进程供给、Vault Proxy 的部署拓扑、以及 Kubernetes 三件套（VSO / CSI provider / Agent Injector）时，可以反复回到这张三栏对照表上，问自己：「这个新组件落在哪一列？它如何接管 token 与机密的归属？」
