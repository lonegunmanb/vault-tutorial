# 恭喜完成实验！

你已经在 Kubernetes 环境中完整体验了 Vault Agent Injector 的工作流：安装 Injector，配置 Kubernetes auth，用 Pod annotation 触发 mutation，把 Vault KV v2 机密渲染到 `/vault/secrets/config.txt`，并对比了默认 init + sidecar 模式与 init-only Job 模式。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| 基线 Pod | Injector 已安装不代表所有 Pod 都会被改写；必须有 Pod template annotation |
| 默认注入 | 带注解的 Pod 会出现 `vault-agent-init`、`vault-agent` 与共享 memory volume |
| 文件消费 | 业务容器可以直接读取 `/vault/secrets/config.txt`，不需要集成 Vault SDK |
| 运行期刷新 | sidecar 可以在 Pod 运行期间重新渲染静态机密 |
| init-only Job | `agent-pre-populate-only` 适合一次性任务，避免 sidecar 阻止 Job 干净结束 |

## 关键心智模型

```text
Pod annotation -> Mutating Webhook -> init/sidecar + memory volume -> /vault/secrets/*
```

后续学习 CSI provider、VSO 与 Kubernetes 集成选型时，可以把本实验作为 sidecar 注入模式的基准：它擅长模板化文件注入，但每个 Pod 都要承担 Agent 容器与启动期可达性约束。