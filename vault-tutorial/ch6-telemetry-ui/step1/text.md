# 第一步：启动 3 节点集群并验证 `/v1/sys/metrics` 的四条访问规则

## 1.1 启动并初始化

按 bootstrap → follower 顺序启动 3 个节点：

```bash
./start-node.sh 1
sleep 3
./start-node.sh 2
./start-node.sh 3
sleep 3
```

对 node-1 执行初始化（为简化课堂演示，使用 1/1 分片）：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh
```

依次解封三个节点。注意：`retry_join` 是异步的，node-2 / node-3 在 node-1 初始化完成后还需要几秒才能从 leader 拉到 raft 状态、进入 `initialized=true`；如果太快 unseal 它们会得到 `Vault is not initialized`。这里在 unseal 前先等待每个 follower 的 `initialized` 翻成 `true`：

```bash
vault operator unseal "$UNSEAL_KEY"

for port in 8210 8220; do
  echo -n "等待 127.0.0.1:${port} 完成 raft join "
  for i in {1..30}; do
    init=$(curl -sS "http://127.0.0.1:${port}/v1/sys/health" 2>/dev/null \
             | jq -r '.initialized' 2>/dev/null)
    if [ "$init" = "true" ]; then
      echo " OK"
      break
    fi
    echo -n "."
    sleep 1
  done
  VAULT_ADDR=http://127.0.0.1:${port} vault operator unseal "$UNSEAL_KEY"
done
sleep 3
```

通过 `find-leader.sh` 找出当前活跃节点的端口：

```bash
LEADER_PORT=$(./find-leader.sh)
echo "leader = ${LEADER_PORT}"

# 任挑一个非 leader 端口作为本节实验的"目标 standby"
for p in 8200 8210 8220; do
  if [ "$p" != "$LEADER_PORT" ]; then
    STANDBY_PORT=$p
    break
  fi
done
echo "standby = ${STANDBY_PORT}"
```

## 1.2 规则一：只有 leader 响应；standby（OSS 版）会返回 307 重定向

先在不带任何特殊处理的情况下，向 leader 与 standby 各自的 `/v1/sys/metrics` 发起请求，观察状态行的差异：

```bash
echo "=== leader: ${LEADER_PORT} ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics"

echo "=== standby: ${STANDBY_PORT} (no -L, observe 307) ==="
curl -sS -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/sys/metrics" | head -n 10
```

预期：leader 返回 `HTTP 200`；standby 返回 `HTTP 307` 并在 `Location` 响应头中给出 leader 的 `api_addr`（即 `http://127.0.0.1:8200/v1/sys/metrics` 这一类）。这就是正文所讲的"OSS 版待命节点对 `/v1/sys/metrics` 不转发、改为重定向"。

## 1.3 规则二：必须带 token；不带或权限不足都会被拒

```bash
# 不带 token
curl -sS -o /dev/null -w "无 token: HTTP %{http_code}\n" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics"
```

预期返回 `HTTP 403`，因为该路径需要带有 `read` 与 `list` 能力的 token。

## 1.4 规则三：必须带正确的 Accept 头才返回 Prometheus 文本格式

不带 Accept 头 / 带任意其它 Accept 值时，端点会返回 JSON 格式的 go-metrics 快照；只有带 `prometheus/telemetry` 或 `application/openmetrics-text` 时才返回 Prometheus 文本：

```bash
echo "=== 不带 Accept：JSON ==="
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" | head -c 200
echo

echo "=== 带 Accept: prometheus/telemetry：文本 ==="
curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/sys/metrics" | head -n 5
```

预期：第一段输出是 JSON，以 `{"Timestamp":"...","Gauges":[...` 这样的字段开头（实际字段顺序可能是 Timestamp / Gauges / Counters / Samples 中的若干个，取决于当前快照里有哪些指标）；第二段输出则是 Prometheus 暴露格式，以标准的 # HELP / # TYPE 注释行开头。

## 1.5 规则四：路径必须显式写 `/v1/sys/metrics`

```bash
echo "--- Prometheus 默认路径 /metrics ---"
curl -sS -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/metrics" | head -n 5

echo
echo "--- /v1 下随便一个不存在的子路径 ---"
curl -sS -o /dev/null -w "/v1/metrics: HTTP %{http_code}\n" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Accept: prometheus/telemetry" \
  "http://127.0.0.1:${LEADER_PORT}/v1/metrics"
```

预期：

- `GET /metrics` 返回 `HTTP 307`，`Location` 指向 `/ui/`——这是 Vault 把所有未识别的根路径**统一重定向到内置 UI** 的默认行为，**并不是**它真的把指标暴露在了 `/metrics`；
- `GET /v1/metrics` 返回 `HTTP 404`——证明指标端点没有挂在 Prometheus 默认的"短路径"上。

这两条共同说明了正文 §3 的第四条规则：Prometheus 抓取作业必须显式设置 `metrics_path: "/v1/sys/metrics"`，否则要么命中 UI 重定向、要么命中 404，都拿不到指标。

## 1.6 这一步的核心闭环

集群已稳定运行；正文中"`/v1/sys/metrics` 的四条访问规则"全部在终端里被复现：只有 leader 直接响应、必须带 token、必须带正确 Accept、路径必须正确。下一步把 standby 改造为允许未授权指标访问，观察其行为转变。
