# 实验完成

恭喜完成 6.8 节的动手实验。回顾本实验复现的几条核心规律：

1. **`/v1/sys/metrics` 的四条访问规则**——只有活跃节点直接响应（OSS 版待命节点会返回 307 重定向至 leader）、必须带具备 `read`+`list` 能力的 token、必须带 `Accept: prometheus/telemetry` 之类的请求头、路径必须是 `/v1/sys/metrics` 而非 Prometheus 默认的 `/metrics`。
2. **`listener.telemetry.unauthenticated_metrics_access` 的双重副作用**——开启后该 listener 上既免除 token 鉴权，又把待命节点的行为从"重定向"翻转为"就地返回自身指标"。
3. **`prefix_filter` 的减法语义**——负向规则在指标暴露阶段就把对应前缀整体屏蔽，且更具体的规则优先于更宽泛的规则，是降低观测后端写入压力的最廉价手段。
4. **拉取式（pull）链路真的能跑通**——本地 Prometheus 按"`metrics_path: /v1/sys/metrics` + `bearer_token` + 指向 leader"三件套抓取，TSDB 中能用 PromQL 查到 `vault_core_unsealed=1`。
5. **推送式（push）链路真的能跑通**——给某节点配上 `statsd_address` 并重启，一个极简 UDP 接收端就能看到形如 `vault.runtime.alloc_bytes:...|g` 的明文指标包；这也直观展示了 sink 类参数**不可** SIGHUP 热加载的事实。
6. **`ui = true` 与 `listener` 共同决定 GUI 暴露面**——UI 与 API 共用同一端口，listener 暴露面一就绪、`ui = true` 一加载，浏览器就能直接访问。

下一步建议：

- 把本实验中的 leader 端口对接一个真实的 Prometheus 实例 + Grafana 看板，观察连续抓取下指标的时序变化；
- 在生产环境推广 `unauthenticated_metrics_access` 时，务必通过网络隔离（私网 listener、反向代理鉴权、防火墙白名单）弥补暴露面，不要在公网 listener 上直接开启；
- 推送式 sink 在生产中常见的真正接收端是 statsd_exporter / Datadog Agent / Stackdriver Agent，把本步的"假 statsd"换成它们即可平滑切到真实观测后端。
