# 第二步：启动 Vault Agent，确认 listener 与 Auto-auth 都已上线

## 2.1 后台启动 Agent

```bash
nohup vault agent -config=/root/agent-cache.hcl \
  > /var/log/vault-agent.log 2>&1 &
sleep 2
```

不要用前台启动——这是一个交互式终端，前台启动会把它占住。

## 2.2 看日志确认 Agent 已经做完两件事

```bash
tail -n 30 /var/log/vault-agent.log
```

应能看到：

- 一行类似 `auth.handler: starting auth handler` 与 `auth.handler: authenticating`，紧接着 `auth.handler: authentication successful` —— 这是 Auto-auth 用 AppRole 完成首次登录；
- 一行 `cache: starting cache listener` 或类似含义的提示，说明 listener 已经绑上 `127.0.0.1:8100`。

如果日志里出现 `error` / `failed to authenticate`，请回到 Step 1 检查 `agent-role-id` / `agent-secret-id` 是否被覆盖、Vault 是否在 8200 上还活着。

## 2.3 确认 Auto-auth token 已经被写入 sink 文件

```bash
ls -l /root/agent-cache/auto-auth-token
head -c 30 /root/agent-cache/auto-auth-token; echo
```

应当看到一个以 `hvs.` 开头的 Vault Token——这正是 Agent 替你登录后拿到的、稍后会用于（a）缓存匹配、（b）替无 token 的客户端贴上 `X-Vault-Token`。

> 这枚 token 由 AppRole 签出，绑定的策略只允许读 `secret/data/agent/static` 与从 `aws/creds/dev-iam` 拿凭据；用它去访问任何其他路径都会被 Vault 拒掉。

## 2.4 确认 listener 真的能接受 HTTP 请求

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8100/v1/sys/health
```

应当输出 `HTTP 200`。这说明 Agent 已经把 `/v1/sys/health` 这条标准 Vault API 路径透传给了 Vault Server——证明 Agent listener 工作正常。

> 注意 `/v1/sys/health` 是 Vault Server 路径，Agent 在这里仅仅做转发，不会缓存它（它既不是 token 创建也不是带租约机密的创建）。下一步我们才会真正打缓存能命中的端点。

## 2.5 这一步的核心闭环

Vault Agent 进程在后台跑、Auto-auth 已成功、listener 监听 `127.0.0.1:8100`、sink 文件里有一枚有效 Vault Token。准备进入第 3 步观察缓存命中。
