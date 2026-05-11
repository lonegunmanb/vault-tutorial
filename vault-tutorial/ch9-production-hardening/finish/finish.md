# 实验完成

恭喜完成 9.1 节的动手实验。回顾本实验复现的几条核心规律：

1. **速率限流配额按 `path` + `rate` + `interval` 三要素定义**——`path="transit"` 即按引擎限流，`path=""` 即全集群兜底；超出阈值的请求被立即以 `HTTP 429` 拒收。
2. **被拒请求默认不进入审计日志**——必须显式 `vault write sys/quotas/config enable_rate_limit_audit_logging=true` 才会被审计设备记录；该开关在异常大流量期间会反向影响 Vault 性能，需谨慎权衡。
3. **`enable_rate_limit_response_headers` 提供客户端自适应退避的标准信号**——打开后响应头里会出现 `X-Ratelimit-*` 与 `Retry-After`，应用代码可以据此做指数退避。
4. **社区版始终按源 IP 分组（`group_by: ip`）**——这一点在所有 `vault read sys/quotas/rate-limit/...` 输出里都可见，是所有规则的隐含前提。

下一步建议：

- 把"上线前安全加固清单"映射到自己组织的实际部署清单，逐条核查是否落地（尤其是非 root 账号、TLS、防火墙、`disable_mlock` 取舍、初始 root token 是否已吊销、审计设备是否已启用）；
- 给生产集群至少配一条 `path=""` 的全局兜底规则；为 `transit/encrypt`、`pki/sign-verbatim` 等昂贵端点单独配规则；为 `auth/userpass/login/*`、`auth/approle/login` 等登录端点配规则，与 [6.9 节 user lockout](https://lonegunmanb.github.io/vault-tutorial/ch6-user-lockout.html) 互补；
- 如果业务对"被拒请求的可追溯性"有要求，把 `enable_rate_limit_audit_logging` 打开，并配套提升审计设备本身的写入吞吐（详见 [8.2 节](https://lonegunmanb.github.io/vault-tutorial/ch8-audit-devices.html)）。
