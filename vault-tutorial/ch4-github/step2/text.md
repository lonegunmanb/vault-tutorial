# 第二步：启用 github 认证 + TOFU 学回 organization_id

![Step 2 故事板：班主任第一次给假 GitHub 这位"新同学"按指纹建档（TOFU 学回 organization_id）](../assets/step2-tofu-fingerprint-story.png)

[4.4 章 §4](/ch4-github) 介绍了 `organization` / `organization_id`
的 TOFU 机制——只填名字时，Vault 会立即调用一次 `GET /orgs/<name>`
把数字 ID 学回 storage。本步在我们的 fake GitHub 上**完整复现**这
条逻辑——你将看到 nginx access.log 中出现一条来自 `go-github` UA
的请求。

## 2.1 启用 github 认证方法

```bash
vault auth enable github
vault auth list | grep github
```

应看到 `github/   github   auth_xxxxx`——挂载在默认路径
`auth/github/`。

## 2.2 写入 `auth/github/config`，触发 TOFU

```bash
vault write auth/github/config organization=hashicorp
```

> **本步骤的关键过程**——Vault 收到该请求后：
> 1. 解析 `organization=hashicorp`
> 2. 由于未填写 `organization_id`，调用 `setOrganizationID()`
> 3. 内部使用 `go-github` SDK 调用
>    `GET https://api.github.com/orgs/hashicorp`
> 4. Go runtime 解析 `api.github.com` → 经 /etc/hosts → 解析为
>    `127.0.0.1`
> 5. Go `crypto/tls` 使用系统 CA 根校验自签证书 → 通过
> 6. nginx 把请求反向代理到 `127.0.0.1:4010`（prism） → prism 按
>    `github-mock.yaml` 返回 `{"login":"hashicorp","id":761456,...}`
> 7. Vault 把 `761456` 写入 `config.organization_id`

应看到 `Success! Data written to: auth/github/config`。

## 2.3 回读 config 查看学到的 ID

```bash
vault read auth/github/config
```

关键字段：

| 字段 | 期望值 |
| :-- | :-- |
| `organization` | `hashicorp` |
| `organization_id` | `761456`（**从 mock 学回，并非用户写入**） |
| `base_url` | `n/a`（保持空，Vault 走默认 `https://api.github.com/`） |
| `token_ttl` / `token_max_ttl` | `0s`（按 mount 默认） |

## 2.4 在 nginx 日志中查看 Vault 实际发出的请求

```bash
tail -5 /var/log/nginx/access.log
```

应能看到一条形如：

```
127.0.0.1 "GET /orgs/hashicorp HTTP/1.1" 200 accept="application/vnd.github.v3+json" ua="go-github"
```

> **三个细节值得关注**：
> - `127.0.0.1` 来源 IP——Vault 进程从本机 loopback 出口访问
>   `api.github.com`，这条记录证明 hosts 重定向已完全生效
> - `Accept: application/vnd.github.v3+json`——`go-github` 的标准
>   header（[4.4 章 §2](/ch4-github)）
> - `ua=go-github`——SDK 内置 User-Agent，与上一步 curl 留下的
>   `ua=curl/...` 形成鲜明对比

## 2.5 反演（一）：故意指定一个不存在的 org

[4.4 章 §4](/ch4-github) 中提到："写 `config` 时如果填的
`organization` 在 GitHub 上**不存在**，Vault 会直接拒绝，错误信息
形如 `unable to fetch the organization_id`"——我们的 mock 仅为
`hashicorp` 这一个 org 准备了 `id`。先临时删除再尝试：

```bash
vault delete auth/github/config 2>/dev/null || true
vault write auth/github/config organization=hashicorp
# 上面这条应再次成功；下面这条按理应失败：
vault write auth/github/config organization=nonexistent-org-xyz
```

> 注意：本实验的 mock 对**任何** org 名都返回同一份
> `{"login":"hashicorp","id":761456,...}`（spec 中 path 参数未参与
> 区分，仅返回 example）——因此严格意义上 mock 并不会拒绝。真正的
> 失败现象会在 Step 4 出现——那一步会修改 mock spec，让 `/orgs/{org}`
> 在某些条件下返回 404。

把 config 还原为 `hashicorp`：

```bash
vault delete auth/github/config 2>/dev/null || true
vault write auth/github/config organization=hashicorp
vault read auth/github/config | grep -E 'organization|base_url'
```

## 2.6 反演（二）：显式手填 organization_id

更安全的做法是直接写死数字 ID、跳过 TOFU。这里故意写一个**错误的**
ID 来观察 Vault 如何拒绝登录（本节只演示写入侧——写入时 Vault 允
许任意 ID，对错要到 Step 3 真实登录时才会暴露）：

```bash
vault write auth/github/config organization=hashicorp organization_id=999999999
vault read auth/github/config | grep organization_id
```

`organization_id` 应显示 `999999999`——Vault 写 config 时**不**校
验 ID 是否真实存在；它要等到下一次登录时才会比对登录方
`/user/orgs` 列表中是否包含此 ID。

把 ID 改回 mock 中的真实值 `761456`：

```bash
vault write auth/github/config organization=hashicorp organization_id=761456
```

## 2.7 本步骤的核心闭环

`vault write auth/github/config organization=hashicorp` 触发了一次
真实的 `GET /orgs/hashicorp`——nginx access.log 中可见相应记录；
TOFU 学回的 `organization_id=761456` 与 mock spec 中的值完全一致；
显式手填 ID 时 Vault 不做实时校验，对错需到真实登录时才会暴露。
下一步将让一个"用户"登入。
