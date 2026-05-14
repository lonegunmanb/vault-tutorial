# 实验完成

恭喜完成 9.5 节的动手实验。回顾本实验复现的几条核心规律：

1. **"systemctl 概要 + journalctl 详情"是服务器进程问题的标准排障路径**——`systemctl`（或本实验里的 `nohup` + `/var/log/vault.log`）只告诉你"启动失败"，真正的根因永远要去日志里取。本实验里 `Cluster address must be set when using raft storage` 就是这一类信息的典型样例。
2. **客户端单次请求失败的第一现场是 CLI / API 输出本身**——`Warning` / `Error` 开头的字符串里通常已经包含定位线索：地址、协议、HTTP 状态码、Go 标准库错误名。`http: server gave HTTP response to HTTPS client` 就是协议层面错误的标志性短语。
3. **dev 模式服务器的启动输出里包含 `VAULT_ADDR` 设置 hint**——养成"先看启动输出再调命令"的习惯，能回避大量典型错误。
4. **`permission denied` 是一种"不可解释"的拒绝**——客户端拿到的就是一句干巴巴的报错，**找根因必须回到审计日志**。审计日志中的 `policy_results.allowed`、`operation`、`path` 三个字段是最关键的取证锚点。
5. **策略修改不会自动应用到已经签发的 token**——所有改完策略的人都必须显式重新登录拿新 token。生产环境给业务方下发的"策略修复完毕"通知里**必须**带这一句。

下一步建议：

- 把本实验中的"取证—推理—修复"三段式套到真实生产环境的故障 runbook 里：每一类故障先定义"从哪里取证"，再定义"看到什么字段就指向什么根因"，最后定义"修复后如何验证"。
- 给生产 Vault 集群至少配两台审计设备（参考 [8.1 节审计设备综述](https://lonegunmanb.github.io/vault-tutorial/ch8-audit-overview.html)）——审计日志是排查 `permission denied` 的唯一权威账本，单点故障不可承受。
- 把 Vault 的遥测指标接到 Prometheus / Grafana（参考 [6.8 节 Telemetry 与 UI](https://lonegunmanb.github.io/vault-tutorial/ch6-telemetry-ui.html)）——本实验未涉及"系统变慢"类的趋势型问题，但生产环境必须配套。
- 把 [9.1 节请求速率限流](https://lonegunmanb.github.io/vault-tutorial/ch9-production-hardening.html) 的 `enable_rate_limit_audit_logging` 打开，让被限流的请求也能进入审计日志，与本实验的策略权限审计形成完整覆盖。
