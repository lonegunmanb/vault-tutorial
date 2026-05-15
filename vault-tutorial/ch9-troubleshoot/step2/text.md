# 第二步：客户端协议不匹配 — 复现 `http: server gave HTTP response to HTTPS client`

## 2.1 重置环境，启动 dev 模式 Vault

第一步遗留的 raft 集群对本步无关。停掉它，用 dev 模式重新拉起（dev 模式默认监听明文 HTTP）：

```bash
./stop-vault.sh

nohup vault server -dev \
  -dev-root-token-id=root \
  -dev-listen-address=0.0.0.0:8200 \
  > /var/log/vault.log 2>&1 &

sleep 3
```

## 2.2 仔细观察 dev 服务器的启动输出

```bash
head -40 /var/log/vault.log
```

> 小贴士：当你在交互终端里直接前台运行 `vault server -dev` 时，启动末尾会额外打印一段醒目的 hint：
>
> ```text
> You may need to set the following environment variables:
>
>     $ export VAULT_ADDR='http://127.0.0.1:8200'
> ```
>
> 这就是 9.5 节情景二反复强调的"故障的解法常常已经被作者写在 hint 段里"。但本实验为了让 Vault 在后台跑，用了 `nohup ... > /var/log/vault.log 2>&1 &`，这段交互式 hint 在 Vault 1.19+ 不会进入文件日志——所以下面我们改用 **配置块** 里的两行更稳定的线索来定位问题。

在 `head -40` 的输出里，重点找出这两行（你应该能直接看到）：

```text
             Api Address: http://0.0.0.0:8200
              Listener 1: tcp (addr: "0.0.0.0:8200", ... tls: "disabled")
```

这两行明确告诉你：**dev 服务器对外暴露的是明文 HTTP（`tls: "disabled"`，`api_addr` 也是 `http://`）**。**先记住这个事实，但不要急着 `export VAULT_ADDR`**——下一步我们故意忽略它，亲自体验"协议不匹配"是什么样子。

## 2.3 故意不导出 `VAULT_ADDR`，直接 `vault status`

清掉环境里可能预设的 `VAULT_ADDR`，模拟"刚开终端、什么都没设置"的状态：

```bash
unset VAULT_ADDR
vault status
```

预期会得到与教程**完全一致**的两行报错（输出可能略有顺序差异，但关键字段不变）：

```text
WARNING! VAULT_ADDR and -address unset. Defaulting to https://127.0.0.1:8200.

Error checking seal status: Get "https://127.0.0.1:8200/v1/sys/seal-status": http: server gave HTTP response to HTTPS client
```

按 9.5 节正文情景二的解读：

- 第一行 `WARNING!` 告诉我们 CLI **回退到了它自己的默认地址 `https://127.0.0.1:8200`**——注意是 `https://`；
- 第二行 `http: server gave HTTP response to HTTPS client` 是 Go HTTP 库专门用于"客户端按 HTTPS 握手却收到 HTTP 响应"的错误名。

两行合起来直接定位了根因：CLI 默认按 HTTPS 连，dev 服务器开的是明文 HTTP，协议不匹配。

## 2.4 按 hint 修复

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
vault status
```

这次 CLI 改用 HTTP 协议去连，与 dev 服务器对齐，能正常返回 seal-status：

```text
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
...
```

## 2.5 这一步的核心闭环

学员亲眼看到"客户端单次请求失败的第一现场就是 CLI / API 输出本身"——`Warning` / `Error` 开头的字符串里通常已经包含定位线索（地址、协议、状态码、错误名），无需翻服务器日志即可定位。同时验证了 9.5 节反复强调的排障习惯：**不要忽略命令启动时打印的 hint 段，故障的解法常常已经被作者写在那里**。
