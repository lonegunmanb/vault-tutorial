# 第四步：拉取式接入端到端——让 Prometheus 真的把指标 pull 走

正文 §3 给出了 Prometheus 拉取 leader `/v1/sys/metrics` 的最小 job 配置。本步在同一台主机上启动一个本地 Prometheus 进程，按那份配置真实地抓一次，再用 Prometheus 自己的 query API 反过来确认指标确实落到了它的 TSDB 里。

## 4.1 找回当前 leader 端口与 root token

每一步进入新的 shell，先把这两个变量重新加载一次：

```bash
source /etc/profile.d/vault.sh
LEADER_PORT=$(/root/find-leader.sh)
echo "leader = ${LEADER_PORT}, token = ${VAULT_TOKEN:0:10}..."
```

预期能输出 `8200`、`8210`、`8220` 中的一个。

## 4.2 写入最小 prometheus.yml

完全照搬正文 §3 的最小 job，只把 `scheme` 改回 `http`、`targets` 指向当前 leader：

```bash
cat > /root/prometheus.yml <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: 'vault'
    metrics_path: /v1/sys/metrics
    scheme: http
    bearer_token: '${VAULT_TOKEN}'
    static_configs:
      - targets: ['127.0.0.1:${LEADER_PORT}']
EOF
cat /root/prometheus.yml
```

> Prometheus 在 scrape 时会自动加上 `Accept: application/openmetrics-text;...` 之类的请求头，因此 §3 第二条规则我们不用手工指定。`bearer_token` 满足第三条（鉴权），`metrics_path` 满足第四条（路径），`targets` 指向 leader 满足第一条（只 leader 响应）。

## 4.3 后台启动 Prometheus

```bash
nohup prometheus \
  --config.file=/root/prometheus.yml \
  --storage.tsdb.path=/tmp/prom-data \
  --web.listen-address=127.0.0.1:9090 \
  > /var/log/prometheus.log 2>&1 &
echo "prometheus pid = $!"

# 等它起来 + 完成至少一次 scrape
for i in {1..15}; do
  if curl -sS "http://127.0.0.1:9090/-/ready" 2>/dev/null | grep -q "Ready"; then
    echo " prometheus 已就绪"
    break
  fi
  echo -n "."
  sleep 1
done
sleep 6
```

## 4.4 用 Prometheus 自己的 query API 验证抓到了数据

先看 target 健康状态：

```bash
curl -sS "http://127.0.0.1:9090/api/v1/targets" \
  | jq '.data.activeTargets[] | {scrapeUrl, health, lastError}'
```

预期 `health` 为 `"up"`、`lastError` 为空字符串。如果是 `down`，看一眼 `/var/log/prometheus.log` 与 leader 的 vault 日志查原因。

再 query 一个一定存在的、值固定为 `1` 的核心指标：

```bash
curl -sS --get \
  --data-urlencode 'query=vault_core_unsealed' \
  "http://127.0.0.1:9090/api/v1/query" \
  | jq '.data.result'
```

预期能看到一条 `vault_core_unsealed` 序列，`value` 数组的第二个元素是字符串 `"1"`——这意味着 leader 节点的 `/v1/sys/metrics` 已经被 Prometheus 真的 pull 走、解析进 TSDB、并能被 PromQL 检索到。

## 4.5 这一步的核心闭环

学员观察到完整的拉取式链路：**Vault leader 把指标暂存内存 → Prometheus 按 §3 四条规则定期抓取 → 指标进入 TSDB → PromQL 查询返回**。下一步演示与之对偶的推送式链路：Vault 主动把指标按周期外发到一个 statsd 接收端。
