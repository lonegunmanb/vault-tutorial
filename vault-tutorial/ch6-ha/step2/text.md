# 第二步：向 standby 发请求——观察默认的请求转发

6.6 节 §3 指出，请求转发自 Vault 0.6.2 起**默认启用**。本步在不做任何额外配置的前提下，把一次写入与读取都直接发往 standby 节点，确认 standby 把请求透明地转发给了 active，客户端没有看到任何重定向。

## 2.1 先在 active 上启用 KV v2 并写入一条数据

为方便后续观察，约定 active 端口为 `${ACTIVE_PORT}`，先随便挑一个 standby 端口为 `${STANDBY_PORT}`。请按上一步 `sys/leader` 的实际结果手动赋值，例如：

```bash
export ACTIVE_PORT=8200
export STANDBY_PORT=8210
```

在 active 上启用 KV v2 引擎并写入一条数据：

```bash
VAULT_ADDR="http://127.0.0.1:${ACTIVE_PORT}" vault secrets enable -path=demo-kv kv-v2

VAULT_ADDR="http://127.0.0.1:${ACTIVE_PORT}" vault kv put demo-kv/hello \
  message="written via active"
```

## 2.2 把同一次读取请求直接打给 standby

把 CLI 临时指向 standby 端口、并保留默认行为（不带任何特殊请求头），读取刚刚那条数据：

```bash
VAULT_ADDR="http://127.0.0.1:${STANDBY_PORT}" vault kv get demo-kv/hello
```

预期输出与在 active 上读取完全一致——客户端拿到了 `message=written via active`，**完全无感**。

## 2.3 用原生 `curl` 复盘一遍：HTTP 层面看到的是什么

CLI 把网络细节抽走了，用 `curl -i` 复盘可以看到 standby 实际返回的 HTTP 报文确实是 `200 OK`，而非任何 `3xx`：

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期：HTTP 状态行是 `HTTP/1.1 200 OK`，响应体里包含 `"message":"written via active"`。

## 2.4 这一步的核心闭环

standby 节点在不做任何特殊配置时**默认就把请求透明转发到了 active**——客户端看到的就是普通 200 响应，没有任何 3xx。这一行为符合 6.5 节 §3 中"自 0.6.2 起请求转发默认启用"的描述。下一步主动关闭这一便利，让 standby 暴露出底层的"307 重定向"。
