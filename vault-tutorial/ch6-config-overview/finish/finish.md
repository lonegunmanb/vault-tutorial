# 实验完成

恭喜你完成本节实验。你已经：

- 阅读了一份最小可启动的 `vault.hcl`，识别出顶层标量参数与命名块；
- 用 `vault server -config=...` 亲手启动了非 dev 模式的 Vault，并完成了初始化与解封；
- 通过修改 `log_level` + 发送 `SIGHUP` 验证了日志级别可被就地热加载，进程不重启；
- 通过故意删除 `disable_mlock` 观察了 Vault 回退为启用 `mlock` 的行为，理解了为什么 raft 配置中通常要显式写出 `disable_mlock = true`。

下一节将基于这份骨架，深入到 `listener` 块的 TLS 协议族强化配置。
