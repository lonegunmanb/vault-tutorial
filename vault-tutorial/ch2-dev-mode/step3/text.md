# 第三步：验证明文传输——tcpdump 截获 Token

这是本实验最直观、最有冲击力的一步。我们将用 `tcpdump` 嗅探本地回环网络流量，直接从网络包中读出 Vault Token 和机密的明文值。

## 3.1 理解攻击面

在没有 TLS 的情况下，每次 Vault API 调用都会在 HTTP 请求和响应中明文暴露：
- **`X-Vault-Token` 请求头**：包含你的身份令牌
- **`X-Vault-Request: true` 请求头**：标识这是一个 Vault API 请求
- **响应体 JSON**：包含机密的明文值

即使是"只监听 `127.0.0.1`"也不够安全——同台机器上以普通用户权限运行的恶意程序可以嗅探本地回环网络。

## 3.2 启动 tcpdump 监听回环网络

打开一个**新的终端标签**（或使用 `&` 后台运行），开始捕获 8200 端口的流量：

```bash
# 开始嗅探（保存到文件，后台运行）
tcpdump -i lo -A -s 0 'tcp port 8200' > /tmp/vault-traffic.cap 2>&1 &
TCPDUMP_PID=$!
echo "tcpdump 已启动，PID: $TCPDUMP_PID"
sleep 1
```

## 3.3 执行几个包含机密的 Vault 操作

```bash
# 写入一个包含敏感值的机密
vault kv put secret/demo/api-key \
  service="payment-gateway" \
  api_key="sk_live_SUPER_SENSITIVE_KEY_9876543210"

# 读取这个机密（这会触发一个 GET 请求，包含 Token 和明文响应）
vault kv get -format=json secret/demo/api-key
```

## 3.4 停止 tcpdump 并分析流量

```bash
# 停止捕获
kill $TCPDUMP_PID
sleep 1

echo ""
echo "======= 捕获到的 HTTP 流量（节选）======="
echo ""
```

### 查找明文 Token

```bash
grep -a "X-Vault-Token" /tmp/vault-traffic.cap | head -5
```

你会看到类似：

```
X-Vault-Token: root
```

**这是你的 Vault Root Token，以明文形式出现在网络包中。**

### 查找明文机密值

```bash
grep -a "api_key\|SUPER_SENSITIVE\|payment" /tmp/vault-traffic.cap | head -10
```

你会看到：

```json
{"request_id":"...","data":{"api_key":"sk_live_SUPER_SENSITIVE_KEY_9876543210","service":"payment-gateway"},...}
```

**机密的完整明文值就在网络包里。**

## 3.5 量化真实攻击场景

以下任何一种情况都能让攻击者截获到上述数据：

| 攻击场景 | 所需权限 | 难度 |
| :--- | :--- | :--- |
| 同一台机器的另一个用户进程 | 普通用户（有 `tcpdump` 权限） | 极低 |
| 同一 Docker network 中的另一个容器 | 无特殊权限 | 低 |
| 同一 Kubernetes Pod 中的 Sidecar | 无特殊权限 | 低 |
| 同一局域网（Dev 监听 0.0.0.0 时） | 无特殊权限 | 低 |
| 云上同 VPC 内的另一台虚机 | 无特殊权限 | 低 |

## 3.6 小结

HTTP Dev 模式下，Token 和机密值以明文出现在每个网络包中。下一步我们将用 `-dev-tls` 模式做一次现场对比，亲眼验证 TLS 开启后嗅探结果的差异。

## 3.7 清理并验证理解

```bash
# 清理捕获文件
rm -f /tmp/vault-traffic.cap

# 验证理解：VAULT_ADDR 的协议是 http 还是 https？
echo "当前 VAULT_ADDR: $VAULT_ADDR"
echo "结论：https = 安全；http = 所有流量明文可见"
```

完成后点击 **Continue** 进入第四步。
