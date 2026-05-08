# 实验说明

本实验配套 [6.8 节正文](/ch6-telemetry-ui)：学员此时已经在概念层理解了"顶层 telemetry 块决定采什么 / 发去哪儿、`/v1/sys/metrics` 端点有四条访问规则、listener.telemetry 子块控制未授权访问、`ui = true` 才开启内置 GUI"这套配置面，本实验把其中可观察的部分变成可在终端里直接复现的现象：

1. 启动 3 节点 Raft 集群，确认只有活跃节点响应 `/v1/sys/metrics`，并依次验证"鉴权 token、Accept 头、路径"三条规则；
2. 给一个待命节点的 `listener` 加入 `telemetry { unauthenticated_metrics_access = true }` 并 SIGHUP 重载，验证它由"重定向到 leader"变为"就地返回自身指标且不需要 token"；
3. 在顶层 `telemetry` 块中追加 `prefix_filter` 与 `filter_default`，对比开启前后被屏蔽前缀的指标条数；
4. **拉取式接入端到端验证**：在同一台主机上启动一个 Prometheus 进程，按正文 §3 的最小 job 配置抓取 leader，随后从 Prometheus 查询 `vault_core_unsealed`，确认指标确实被 pull 走；
5. **推送式接入端到端验证**：在同一台主机上启动一个轻量 statsd 接收端（一个小 Python 脚本即可），给某个节点追加 `statsd_address` 并重启，在接收端输出中看到 `vault.runtime.alloc_bytes:...|g` 之类的推送数据；
6. 通过 Killercoda 浏览器入口访问 `:8200/ui/`，确认 GUI 可访问并完成一次 root token 登录。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成——3 个 Vault 进程通过 `0.0.0.0` 上的不同端口隔离（API 8200/8210/8220、cluster 8201/8211/8221）。每个节点的 `api_addr` 都配置为指向 `127.0.0.1` 上的自身端口。

实验开始时，环境已完成下列准备：

- 已安装 `vault`（1.19.2）与 `jq`、`curl`、`prometheus`（1 份本地二进制，供 step4 启动 scrape）与 `python3`（step5 中用作轻量 statsd 接收端）；
- 已为 3 个节点预置 `vault.hcl`，其中已经预置好最小可工作的顶层 `telemetry` 块（`prometheus_retention_time = "30s"`、`disable_hostname = true`），以及 `ui = true`；
- 已为每个节点预创建独立的 raft 数据目录 `/opt/vault/data-{1,2,3}`；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/`，登录 shell 自动加载；
- 已生成便捷启动脚本 `/root/start-node.sh`、以及找出当前 leader 端口的 `/root/find-leader.sh`。

> 本实验全程使用明文 HTTP（`tls_disable = true`），目的是让 `curl -i` 输出干净易读、便于直接观察 `307` 重定向与 Prometheus 文本格式输出。生产环境请按 6.2 节的基线启用 TLS。
