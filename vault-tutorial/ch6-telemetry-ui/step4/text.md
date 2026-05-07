# 第四步：开启 UI 并访问内置 GUI

`ui = true` 已经在初始环境中预置好（参见 `init.md`），且各节点 listener 都绑定到 `0.0.0.0`，因此只需通过 Killercoda 提供的浏览器端口入口即可访问 GUI。

## 4.1 确认 ui 已开启 & GUI 路径可达

通过 `curl` 直接命中 `/ui/`，确认服务端会返回 HTML 而非 404 / 重定向：

```bash
curl -sS -i "http://127.0.0.1:${LEADER_PORT}/ui/" | head -n 15
```

预期看到 `HTTP/1.1 200 OK` 与一段 HTML 起始片段（包含 `<title>` 等）。如果看到 `404`，则说明配置文件中的 `ui = true` 未被加载——回到 `vault.hcl` 检查。

> 如果想关掉 UI 看一下对照效果，可把任一节点配置中的 `ui = true` 改成 `ui = false`、SIGHUP 重载、再次抓 `/ui/`，会得到 `404`。

## 4.2 通过 Killercoda 浏览器入口访问

Killercoda 控制条上方提供"Traffic / Ports"按钮，点击后选择端口 `8200`（即 `LEADER_PORT` 不一定是 8200——若不是，可暂时把 leader 节点改为绑定 8200，或直接访问当前 leader 端口对应的 Killercoda URL）。打开后地址栏中拼上 `/ui/` 即可看到 Vault GUI 登录页。

在登录页选择 "Token" 方式，填入实验环境保存在 `$VAULT_TOKEN` 中的 root token：

```bash
echo "登录用 root token："
echo "$VAULT_TOKEN"
```

复制粘贴后即可进入 GUI 主面板。

## 4.3 观察 token TTL 与 3 分钟静止规则（可选）

正文 §5 强调，UI 的会话超时由两条规则共同决定：

- 自动续期发生在所登录 token 寿命过半时；
- 用户对 Vault API 的最近一次请求之后，若保持静止超过 3 分钟，UI 会停止自动续期，让 token 自然到期。

可以做一个轻量验证：在终端用一条短 TTL 的 token 替换 root token，再用该短 token 登录 GUI，记录登录时刻与登出/失效时刻：

```bash
SHORT_TOKEN=$(vault token create -ttl=10m -policy=default -format=json \
  | jq -r '.auth.client_token')
echo "短 token (10m TTL): ${SHORT_TOKEN}"
```

退出 GUI 后用该 token 重新登录，登录后立即关闭浏览器或保持完全静止 4 分钟以上不操作，再回来刷新——若 token 已过期，GUI 会跳回登录页，证明"静止 3 分钟后停止续期、token 在原 TTL 上自然到期"的描述。

> 由于浏览器在 GUI 后台仍可能触发心跳类的 API 调用，"4 分钟"是一个稍长于规则下限的保守值。完全严格的复现需要把浏览器标签彻底切走或最小化。

## 4.4 这一步的核心闭环

`ui = true` 与 `listener` 共同决定的暴露面、以及 token TTL × 3 分钟静止规则共同决定的会话生命周期，两条核心规律都已落到实际操作之上。至此整章动手实验完成。
