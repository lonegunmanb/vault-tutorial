# 实验完成

你已经在一台主机上跑通了 9.8 节里描述的两条遗留应用接入路径：

- **Consul-Template + 配置文件**：以 30 秒 TTL 的 PostgreSQL 动态凭据为例，演示了模板渲染、`lease_renewal_threshold = 0.5` 触发的自动重申，以及它的固有缺陷——"应用还没来得及重读旧凭据已经被撤"那段窗口；
- **Vault Agent Process Supervisor Mode**：同样的 binary、同样的 AppRole，把动态凭据以 `DB_USER` / `DB_PASSWORD` 注入子进程，并通过 `restart_on_secret_changes = "always"` 在 lease 接近过期时主动 SIGTERM + 重新 exec，从应用角度看就是一次干净的"重启换密码"。

## 你掌握的要点

- PostgreSQL `database` 机密引擎的 `creation_statements` 模板 + `default_ttl=30s` 怎么搭配 `INHERIT` + `GRANT ro` 的最小权限模型；
- Consul-Template 配置里 `renew_token` / `default_lease_duration` / `lease_renewal_threshold` 三个参数的真实作用；
- Vault Agent Process Supervisor Mode 三个约束：必须有 ≥1 个 `env_template`、必须有恰好 1 个 `exec`、不能与文件 `template` 块同存；
- `restart_on_secret_changes` 与 `restart_stop_signal` 怎么决定子进程的关闭语义；
- 用 `pg_user` / `vault list sys/leases/lookup/...` / 主动 `vault lease revoke` 三种角度交叉验证 lease 生命周期。

## 生产化的下一步

- 别在生产里用 root token + dev mode：把 AppRole 的 secret-id 换成 wrapped、用 `response-wrapping` 派发；
- 把 30 秒 TTL 调到符合应用 SLA 的值（一般几十分钟），并配合监控 lease 续期失败率；
- Process Supervisor Mode 适合"一次启动"的二进制；如果应用本身就支持 SIGHUP 重读，Consul-Template 路径反而更轻量；
- 真正混合负载下还可以让 Agent 同时承担"缓存代理"（第 9.3 节）与"模板渲染"职责，但**不能**把 `env_template` 与文件 `template` 写进同一份配置。
