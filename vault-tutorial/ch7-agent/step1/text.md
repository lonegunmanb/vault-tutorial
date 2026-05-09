# 第一步：检查 Agent 配置骨架

先确认 Vault dev server 已经可用，并查看实验预置的 KV v2 机密。

```bash
vault status
vault kv get secret/agent/app
```

查看文件模板 Agent 的配置。重点观察三组配置：`vault` 指向真实 Vault Server，`auto_auth` 使用 AppRole 文件登录，`template` 把模板渲染到 `/root/agent-demo/app.env`。

```bash
sed -n '1,80p' /root/agent-file.hcl
```

再查看模板文件本身。KV v2 的业务数据位于 `.Data.data` 下，因此模板会从 `secret/data/agent/app` 读取 `username`、`password` 与 `api_key`。

```bash
cat /root/agent-file.ctmpl
```

最后查看 AppRole 的 role ID 与 secret ID 文件。Agent 会读取这两个文件完成 Auto-auth，应用进程本身不需要持有 root token。

```bash
ls -l /root/agent-role-id /root/agent-secret-id
cut -c 1-8 /root/agent-role-id && echo
```

本步骤只阅读配置，不启动 Agent。请确认你已经看到了 `static_secret_render_interval = "10s"`，后续会用这个较短间隔观察 KV v2 静态机密的重新渲染。