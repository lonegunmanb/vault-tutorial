# 第六步：开启 UI 并访问内置 GUI

`ui = true` 已经在初始环境中预置好（参见 `init.md`），且各节点 listener 都绑定到 `0.0.0.0`，因此只需通过 Killercoda 提供的浏览器端口入口即可访问 GUI。

## 6.1 确认 ui 已开启 & GUI 路径可达

通过 `curl` 直接命中 `/ui/`，确认服务端会返回 HTML 而非 404 / 重定向：

```bash
curl -sS -i "http://127.0.0.1:${LEADER_PORT}/ui/" | head -n 15
```

预期看到 `HTTP/1.1 200 OK` 与一段 HTML 起始片段（包含 `<title>` 等）。如果看到 `404`，则说明配置文件中的 `ui = true` 未被加载——回到 `vault.hcl` 检查。

> 如果想关掉 UI 看一下对照效果，可把任一节点配置中的 `ui = true` 改成 `ui = false`、SIGHUP 重载、再次抓 `/ui/`，会得到 `404`。

## 6.2 通过 Killercoda 浏览器入口访问

Killercoda 把环境内的 HTTP 端口映射成一个公网可达的临时 URL。打开方式有两种，任选其一：

- **终端右上角的 "Traffic / Ports" 按钮**：点开后选择当前 leader 对应的端口（`8200` / `8210` / `8220` 三个都可以——三个 listener 都绑在 `0.0.0.0`，OSS 版的 standby 在收到 UI 请求时会自动 307 重定向到 leader 的 `api_addr`，所以即便选错端口浏览器也会被自动跳走）；
- **直接点下面的占位链接**（Killercoda 会在渲染时把 `{{TRAFFIC_HOST1_PORT}}` 替换成真实 URL）：
  - 端口 8200：[打开 node-1 UI]({{TRAFFIC_HOST1_8200}}/ui/)
  - 端口 8210：[打开 node-2 UI]({{TRAFFIC_HOST1_8210}}/ui/)
  - 端口 8220：[打开 node-3 UI]({{TRAFFIC_HOST1_8220}}/ui/)

> 注意：Killercoda 的 Traffic 通道只支持 **HTTP**，不支持 HTTPS。本章 listener 全部用的是明文 HTTP，符合要求。

打开后会进入 Vault GUI 登录页，选择 "Token" 方式，填入实验环境保存在 `$VAULT_TOKEN` 中的 root token：

```bash
echo "登录用 root token："
echo "$VAULT_TOKEN"
```

复制粘贴后即可进入 GUI 主面板，尝试在其中浏览 `secret/` 挂载或开启一个新的 KV v2 引擎，验证 GUI 与底层 API 在同一个 listener 上互通。

## 6.3 这一步的核心闭环

`ui = true` 与 `listener` 共同决定的 GUI 暴露面已落到实际操作之上：UI 与 API 共用同一端口，只要 listener 暴露面就绪、`ui = true` 已加载，浏览器端就能直接访问。至此整章动手实验完成。
