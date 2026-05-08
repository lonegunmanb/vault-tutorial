# 第二步：向 standby 发请求——观察默认的请求转发

6.6 节 §3 指出，请求转发自 Vault 0.6.2 起**默认启用**。本步在不做任何额外配置的前提下，把一次写入与读取都直接发往 standby 节点，确认 standby 把请求透明地转发给了 active，客户端没有看到任何重定向。

## 2.1 先在 active 上启用 KV v2 并写入一条数据

为方便后续观察，约定 active 端口为 `${ACTIVE_PORT}`，并任选一个 standby 端口作为 `${STANDBY_PORT}`。请按上一步 `sys/leader` 的实际结果手动赋值，例如：

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

## 2.2 将同一次读取请求直接发送至 standby

将 CLI 临时指向 standby 端口，并保留默认行为（不附加任何特殊请求头），读取上一步写入的数据：

```bash
VAULT_ADDR="http://127.0.0.1:${STANDBY_PORT}" vault kv get demo-kv/hello
```

预期输出与在 active 上读取完全一致——客户端拿到了 `message=written via active`，**完全无感**。

## 2.3 使用原生 `curl` 复核一次：HTTP 层面观察到的实际响应

CLI 屏蔽了底层网络细节，使用 `curl -i` 可观察到 standby 实际返回的 HTTP 报文为 `200 OK`，而非任何 `3xx` 状态码：

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期：HTTP 状态行是 `HTTP/1.1 200 OK`，响应体里包含 `"message":"written via active"`。

## 2.4 这一步的核心闭环

standby 节点在未做任何特殊配置时**默认即将请求透明转发至 active**——客户端收到的是标准的 200 响应，未出现任何 3xx。该行为符合 6.5 节 §3 中"自 0.6.2 起请求转发默认启用"的描述。下一步将主动关闭该机制，使 standby 显式返回底层的"307 重定向"。
