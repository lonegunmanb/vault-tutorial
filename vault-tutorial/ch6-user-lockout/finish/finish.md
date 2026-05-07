# 实验完成

恭喜完成 6.9 节的动手实验。回顾本实验复现的几条核心规律：

1. **user lockout 状态机**——达到 `lockout_threshold` 后用户进入锁定窗口，窗口期内即便提供正确密码也会被立即以 `permission denied` 拒绝；窗口期由 `lockout_duration` 决定。
2. **`/sys/locked-users` 的两条 API**——`GET` 用于按命名空间与 mount accessor 列出当前所有被锁用户，`POST /sys/locked-users/:accessor/unlock/:alias` 用于主动解锁，且解锁端点是**幂等**的。
3. **禁用优先级链的最顶层**——`VAULT_DISABLE_USER_LOCKOUT` 环境变量会无视配置文件中的所有 `user_lockout` 块和挂载点 tune 设置，是线上误锁定事故的最直接应急开关。

下一步建议：

- 在生产环境尽量**不要**像本实验这样把 `lockout_duration` 设到 1 分钟；常见的稳态选型是把 threshold 设到 5\~10、duration 与 counter_reset 各设到 15 分钟左右——既挫败暴力破解，又给真实用户的偶发输错留出温和的恢复窗口。
- 如果接入了集中式日志或 SIEM，把"被锁定"事件作为一类显著的告警源；它通常意味着账户面临凭据填充（credential stuffing）攻击，或者上游某个集成系统正在以错误凭据反复重试。
- 在用 ldap 或 approle 时，重新审视各自的 `user_lockout` 块——三种认证方法对"短时间内大量失败"的容忍度是不一样的（例如 approle 的 secret_id 多为机器使用，重试模式与人类用户差异很大）。
