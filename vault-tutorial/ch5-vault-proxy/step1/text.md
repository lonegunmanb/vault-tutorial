# 第一步：阅读 Proxy 配置与预置身份

先确认 Vault 已经可用。

```bash
vault status
```

查看本实验预置的 AppRole。Proxy 稍后会读取 `/root/proxy-role-id` 和 `/root/proxy-secret-id`，使用这两个文件中的值自动登录 Vault。

```bash
vault read auth/approle/role/proxy-app
echo "role_id=$(cat /root/proxy-role-id)"
test -s /root/proxy-secret-id && echo "secret_id file exists"
```

查看这个 AppRole 关联的最小权限策略。

```bash
vault policy read proxy-app-read
```

这个策略只允许读取 `secret/data/proxy/app`，并允许查询自身 token。它不能读取系统挂载信息，也不能管理其他机密。

查看 Proxy 配置文件。

```bash
sed -n '1,120p' /root/proxy-config.hcl
```

请重点观察五个块：

| 配置块 | 本实验中的作用 |
| :--- | :--- |
| `vault` | 指向真正的 Vault server：`http://127.0.0.1:8200` |
| `auto_auth` | 使用 AppRole 文件自动取得 Vault token |
| `sink` | 把 Auto-auth token 写入 `/root/proxy-token` |
| `api_proxy` | 使用 `use_auto_auth_token = "force"` 强制代理请求使用 Proxy token |
| `listener` | 在 `127.0.0.1:8100` 接收代理请求，并要求 `X-Vault-Request: true` |

这一阶段的关键点是：Proxy 配置文件同时描述“到哪里找 Vault”“怎样登录 Vault”“在哪里接收应用请求”和“代理请求使用哪一个 token”。
