# 第五步：推送式接入端到端——Vault 主动 push 到 statsd 接收端

正文 §2.2 把 sink 分为推送式（push）与拉取式（pull）两类。上一步验证了拉取式（Prometheus），本步验证推送式：在同一台主机上起一个**极简 statsd UDP 接收端**，给某个 Vault 节点的顶层 `telemetry` 块追加 `statsd_address`，重启该节点，然后在接收端的输出里看到 Vault 主动 push 出来的指标包。

## 5.1 启动一个 30 行 Python 写成的 statsd 监听器

statsd 的线上协议非常简单：每个 UDP 包就是一行形如 `metric.name:value|type|@sample_rate` 的纯文本。我们不需要真实的 statsd / statsite 服务器，只要一个能把收到的每一行写到日志里的 UDP 监听器就够了：

```bash
cat > /root/fake-statsd.py <<'PY'
import socket, sys, time
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 8125))
print(f"[fake-statsd] listening on 127.0.0.1:8125", flush=True)
while True:
    data, _ = sock.recvfrom(65535)
    for line in data.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line:
            print(f"{time.strftime('%H:%M:%S')} {line}", flush=True)
PY

nohup python3 -u /root/fake-statsd.py > /var/log/fake-statsd.log 2>&1 &
echo "fake-statsd pid = $!"
sleep 1
head -n 5 /var/log/fake-statsd.log
```

预期看到一行 `[fake-statsd] listening on 127.0.0.1:8125`。

## 5.2 给 node-1 追加 statsd_address 并重启

> **注意**：与 step3 的 `prefix_filter` 不同，新增 / 修改 sink 类参数（`statsd_address`、`prometheus_retention_time` 等）**不能**通过 SIGHUP 热加载——这些 sink 实例在进程启动时一次性构造。所以这里要走"改配置 → 停进程 → 重启"的路径。

```bash
# 在 node-1 顶层 telemetry 块里追加 statsd_address
grep -q 'statsd_address' /root/vault-1.hcl || \
  sed -i 's|disable_hostname          = true|disable_hostname          = true\n  statsd_address            = "127.0.0.1:8125"|' \
  /root/vault-1.hcl

grep -A 5 'telemetry {' /root/vault-1.hcl
```

预期顶层 telemetry 块形如：

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
  statsd_address            = "127.0.0.1:8125"
}
```

重启 node-1：

```bash
PID=$(cat /tmp/vault-1.pid 2>/dev/null)
[ -n "$PID" ] && kill "$PID"
sleep 2
/root/start-node.sh 1
sleep 3

# node-1 会以 sealed 状态启动；不论它原本是 leader 还是 follower，重启后都需要 unseal 才能继续上报。
# 直接从 init-output.json 读 unseal key，避免依赖跨 shell 传递的环境变量。
vault operator unseal -address="http://127.0.0.1:8200" \
  "$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)" || true
```

## 5.3 等几十秒，看接收端是否出现 Vault 推送出来的指标

statsd sink 默认每隔 ~10s 把内存里聚合好的指标 flush 一批出来。等 30 秒再看：

```bash
echo "等 30 秒让 Vault flush 至少 2 批指标 ..."
sleep 30

echo "--- /var/log/fake-statsd.log 最新 20 行 ---"
tail -n 20 /var/log/fake-statsd.log

echo
echo "--- 收到的 vault.runtime.* 指标条数 ---"
grep -c '^[0-9:]\+ vault\.runtime\.' /var/log/fake-statsd.log
```

预期能看到大量形如以下的行：

```
21:30:42 vault.runtime.alloc_bytes:12345678|g
21:30:42 vault.runtime.num_goroutines:55|g
21:30:42 vault.runtime.heap_objects:200000|g
...
```

后缀 |g 表示 gauge 类型，|c 表示 counter，|ms 表示 timing/histogram——这就是 statsd 协议的原始字面量。看到这些数据，就证明 Vault 确实在通过 push sink 主动外发指标。

## 5.4 这一步的核心闭环

学员同时把正文 §2.2 列出的两类 sink 都跑了一遍：

- **推送式（本步）**：Vault 进程主动把指标按周期通过 UDP 发到外部 statsd 接收端；
- **拉取式（上一步）**：Vault 把指标暂存内存，由 Prometheus 主动来 `/v1/sys/metrics` 拉。

下一步切回 UI 维度，验证 `ui = true` 与 `listener` 共同决定的 GUI 暴露面。
