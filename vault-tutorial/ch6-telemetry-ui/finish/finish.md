# 实验完成

恭喜完成 6.8 节的动手实验。回顾本实验复现的几条核心规律：

1. **`/v1/sys/metrics` 的四条访问规则**——只有活跃节点直接响应（OSS 版待命节点会返回 307 重定向至 leader）、必须带具备 `read`+`list` 能力的 token、必须带 `Accept: prometheus/telemetry` 之类的请求头、路径必须是 `/v1/sys/metrics` 而非 Prometheus 默认的 `/metrics`。
2. **`listener.telemetry.unauthenticated_metrics_access` 的双重副作用**——开启后该 listener 上既免除 token 鉴权，又把待命节点的行为从"重定向"翻转为"就地返回自身指标"。
3. **`prefix_filter` 的减法语义**——负向规则在指标暴露阶段就把对应前缀整体屏蔽，且更具体的规则优先于更宽泛的规则，是降低观测后端写入压力的最廉价手段。
4. **`ui = true` 与 `listener` 共同决定 GUI 暴露面**，会话生命周期由 token TTL × 3 分钟静止规则共同管控；UI 自身不提供独立的会话超时配置。

下一步建议：

- 把本实验中的 leader 端口改造为对接一个真实的 Prometheus 实例（仅需把示例中的 `scrape_configs` 与 bearer token 落到 `/etc/prometheus/prometheus.yml`），观察连续抓取下指标的时序变化；
- 在生产环境推广 `unauthenticated_metrics_access` 时，务必通过网络隔离（私网 listener、反向代理鉴权、防火墙白名单）弥补暴露面，不要在公网 listener 上直接开启。
