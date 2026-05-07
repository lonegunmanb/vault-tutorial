# 第三步：加 `X-Vault-No-Request-Forwarding` 头——观察 307 重定向

6.6 节 §3 指出：客户端可以通过给请求加 `X-Vault-No-Request-Forwarding: <任意非空值>` 来强制 standby 走"重定向"路径，而不是"转发"路径。本步把这一开关打开，直接观察 HTTP 状态行与 `Location` 头。

## 3.1 直接用 `curl` 强制走重定向

继续使用上一步的 `${ACTIVE_PORT}` 与 `${STANDBY_PORT}` 环境变量：

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "X-Vault-No-Request-Forwarding: 1" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期输出的关键字段：

- 状态行：`HTTP/1.1 307 Temporary Redirect`
- 响应头：`Location: http://127.0.0.1:${ACTIVE_PORT}/v1/demo-kv/data/hello`
- 响应体为空（重定向不带数据）

请把 `Location` 头里的地址与 §1.2 中 `sys/leader` 给出的 `leader_address` 字段对比——两者完全一致。这正是 6.6 节 §4 所述：standby 用 `307` 把客户端送回 **active 节点的 `api_addr`**。

## 3.2 让 `curl` 自动跟随重定向：观察"两跳"过程

加上 `-L` 让 `curl` 自动跟随 `307`，再次请求：

```bash
curl -i -L \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "X-Vault-No-Request-Forwarding: 1" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期看到两段 HTTP 报文背靠背地打印出来：第一段是 standby 返回的 `307` + `Location`；第二段是 `curl` 用同一个 token 重新打到 active、收到 `200 OK` 与真实数据。这就是"客户端重定向"路径的完整 4 步：客户端 → standby → 307 → 客户端 → active → 200。

## 3.3 对照实验：把 header 拿掉，确认 standby 立刻退回到默认的转发路径

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期再次看到 `200 OK` + 数据——同一个 standby、同一个客户端、同一个 token，**仅仅因为去掉了那一个请求头，行为就从"307 重定向"切换回了"透明转发"**。这一对照也验证了：转发与重定向是 standby 在每次请求级别上做的二选一决策，由请求头控制，与节点本身的状态无关。

## 3.4 这一步的核心闭环

通过 `X-Vault-No-Request-Forwarding` 头可以稳定复现 6.6 节 §4 描述的 `307` 重定向行为，并通过 `Location` 头观测到 active 的 `api_addr`。下一步触发一次真实的 leader 切换，验证两条路径都会随新 leader 自动迁移。
