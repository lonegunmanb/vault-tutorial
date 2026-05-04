# 恭喜完成 GitHub 认证实验！🎉

本节通过 **Prism + Nginx + 自签证书 + /etc/hosts 劫持**搭建了一个
让 Vault 完全无法分辨真伪的 `api.github.com`，并把 [4.4 章](/ch4-github)
中 GitHub 认证的几条 GitHub API、TOFU `organization_id`、team /
user 双映射、几种典型失败现场、以及 PAT 风险缓解全部完整执行了
一遍。

## 本实验的核心收获

| 阶段 | 你完整验证的事实 |
| :--- | :--- |
| **自签证书 + 系统 CA 根** | 把自签 CA 复制到 `/usr/local/share/ca-certificates/` 后执行 `update-ca-certificates`，新启动的 Vault 进程立刻把它视为合法 CA——Go `crypto/tls` 默认走 SystemCertPool |
| **/etc/hosts 重定向 + Nginx TLS 反向代理** | `127.0.0.1 api.github.com` + Nginx 监听 443 反代 4010，curl `https://api.github.com/...` 不带任何特殊参数即可成功——证明 DNS / TLS / HTTP 三层全部成功替换 |
| **Prism 4.10.5 mock GitHub API** | `/user`、`/user/orgs`、`/user/teams`、`/orgs/{org}` —— 配置阶段 1 条 (`/orgs/{org}`)、登录阶段 3 条；**Vault 1.19.2 vendored 版 `go-github`** 仍在 `/user/teams` 上发送 `application/vnd.github.hellcat-preview+json`（实现细节，不是协议合同），缺少则 Prism 返回 406 |
| **TOFU organization_id** | `vault write auth/github/config organization=hashicorp` 内部触发 `GET /orgs/hashicorp`，把 `id=761456` 学回 storage——nginx access.log 中可见一条 `ua=go-github` 记录 |
| **完整执行 3 条 API 的 login** | `vault login -method=github token=anything` 顺序调用 `/user` → `/user/orgs` → `/user/teams`（常态下 `/orgs/{org}` 不会被重复调用），按 `map/teams/dev` + `map/users/testuser` 叠加出 policies、签发携带 `username` / `org` metadata 的 token |
| **失败现场（一）跨 org** | `/user/orgs` 不返回目标 org → `user is not part of required org` |
| **失败现场（二）team 无映射** | `/user/teams` 仅返回未映射 team → 登录成功，token 仅携带 `default` + user 映射的 policy，**不报错** |
| **失败现场（三）org rename** | id 不变只改 login 名 → 登录成功 + warning `the organization name has changed to ...` |
| **token_bound_cidrs 收紧** | 登录方 `127.0.0.1` 不在 `10.99.0.0/24` → `Code: 403, permission denied`（github 后端在 `verifyCredentials` 第一步即拒绝，不暴露细节） |
| **级联吊销** | `vault auth disable github` 立刻让所有由该 mount 签发的 token 失效 |

## 整章一图总结

```
            ┌──────────────────────────────────────────────────┐
            │       GitHub 认证方法（trusted 3rd-party）       │
            │  信任根：GitHub（PAT 由 GitHub 颁发）            │
            │  目标用户：人类（运维 / 开发者直接 CLI 使用）    │
            └──────────────────┬───────────────────────────────┘
                               │
   vault login -method=github token=ghp_xxxxxx
                               │
                               ▼
   Vault → go-github SDK → 配置阶段 1 条 + 登录阶段 3 条 REST 调用：
   ┌────────────────────────────────────────────────────────────┐
   │  【配置】GET /orgs/{org}      仅在缺 `organization_id` 时被调 (TOFU) │
   │  【登录】GET /user            (Accept v3+json) → username           │
   │  【登录】GET /user/orgs       (Accept v3+json) → 校验属于目标 org   │
   │  【登录】GET /user/teams      (1.19.2: hellcat-preview) → 列 team    │
   └─────────────────────────────────────────────────────────────┘
                               │
   token policies = default + map/teams/<slug> + map/users/<login>
   token metadata = {username, org}
   token alias    = <github username>     → identity entity 自动绑定

   缓解措施：
   - token_ttl / token_max_ttl 短寿命
   - token_bound_cidrs 限定源 IP
   - PAT 使用 fine-grained + 短过期
   - SSO org 务必预先 authorize PAT

   三层"假 GitHub"全栈替换（本实验所做）：
   - DNS：/etc/hosts 把 api.github.com → 127.0.0.1
   - TLS：自签证书 SAN=api.github.com，安装到 /usr/local/share/ca-certificates
   - HTTP：Nginx :443 反向代理 → Prism :4010 按 OpenAPI spec 静态返回
```

## 后续阅读

回到 [4.4 章正文](/ch4-github)：

- §2 中的 API 表 + Accept header 区别——你在 step 2 / step 3 中
  通过 nginx access.log 逐条核对过
- §4 organization_id TOFU——你在 step 2 中观察到它从 mock 学回
  761456
- §5 team / user 双映射叠加——你在 step 3 中看到了 `[default,
  dev-policy, oncall-policy]` 这三条
- §7 PAT 风险模型 + 缓解——`token_bound_cidrs` 在 step 4 中演示
- §9 base_url + 自建模拟 + GHES——你完成的正是最完整的"端到端
  模拟"路径

下一节预告：第 4 章后续小节将继续逐个介绍 Auth Method 的动手实
验——`kubernetes`（Service Account JWT 验证）、`jwt/oidc`（企业
IdP 接入）、`cert`（mTLS 客户端证书）等。
