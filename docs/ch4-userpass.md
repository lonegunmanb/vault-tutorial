---
order: 47
title: 4.8 Userpass 认证：Vault 内置用户名密码登录
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.8 Userpass 认证：Vault 内置用户名密码登录

> **核心结论**：`userpass` 是 Vault 自带的用户名/密码认证方法。用户名、密码和登录后签发 token 的参数直接配置在 `auth/userpass/users/<username>` 下；用户提交用户名和密码后，Vault 验证成功就签发 token。它不读取外部目录里的用户名密码，所以不要把它误当成 LDAP、OIDC 或企业目录的替代品。

参考：
- [Userpass Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/userpass)
- [Userpass Auth Method HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/userpass)
- [Killercoda Creator Documentation](https://killercoda.com/creators)

---

## 1. userpass 在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 的分类框架，`userpass` 是最直观的凭据型认证：用户交出 username/password，Vault 验证后签发 Vault token。它的外部凭据不是云平台身份、Kubernetes service account、TLS 客户端证书，也不是 LDAP 目录密码，而是直接存放在这个 auth method 自己的 `users/` 路径中。

官方文档明确说，`userpass` 不能从外部来源读取 username/password 组合；也就是说，它不会自动连接公司 LDAP、数据库或 OIDC provider。要接外部目录，应该选择对应的 auth method，例如 LDAP 或 OIDC，而不是把 `userpass` 当成同步目录的工具。

![userpass 认证：本地用户名密码换取 Vault token](/images/ch4-userpass/userpass-flow.png)

---

## 2. mount path 与登录路径

默认启用方式是 `vault auth enable userpass`，挂载路径为 `auth/userpass/`；也可以用 `vault auth enable -path=<path> userpass` 挂到自定义路径。官方文档提醒，如果挂载路径不是默认值，CLI 和 API 调用路径也要相应调整。

默认路径下，CLI 登录命令是：`vault login -method=userpass username=mitchellh password=foo`；API 登录端点是 `POST /auth/userpass/login/:username`，请求体里放 `password`，返回 token 在 `auth.client_token` 中。

Vault 会把提交的用户名转成小写：官方示例说明 `Mary` 和 `mary` 被视为同一个条目。因此，在生产中最好提前约定用户名规范，避免大小写差异给排障带来错觉。

```bash
# 启用
vault auth enable userpass

# CLI 登录
vault login -method=userpass username=alice password=alice-pwd

# HTTP API 登录
curl -s --request POST \
  --data '{"password":"alice-pwd"}' \
  http://127.0.0.1:8200/v1/auth/userpass/login/alice | jq .auth.client_token
```

---

## 3. 创建用户：密码、policy 与 token 参数

创建或更新用户的 API 路径是 `POST /auth/userpass/users/:username`。创建用户时，必须提供 `password` 或 bcrypt 格式的 `password_hash` 之一；两者互斥。

用户名有字符限制：允许字母数字以及 `_`、`-`、`.`；不能以 hyphen 开头，也不能以 period 开头或结尾。

用户条目上可以配置 `token_policies`、`token_ttl`、`token_max_ttl`、`token_bound_cidrs`、`token_num_uses`、`token_type` 等 token 参数。登录成功后，Vault 会按这些参数签发 token。

```bash
# 创建用户（同时绑定 policy 与 token TTL）
vault write auth/userpass/users/alice \
    password="alice-pwd" \
    token_policies="team-reader" \
    token_ttl="20m"

# 等价的 HTTP API
curl -s --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"password":"alice-pwd","token_policies":"team-reader","token_ttl":"20m"}' \
  http://127.0.0.1:8200/v1/auth/userpass/users/alice

# 列出、读取
vault list auth/userpass/users
vault read auth/userpass/users/alice
```

![userpass 用户登记册：用户条目直接绑定 token 参数](/images/ch4-userpass/userpass-local-user-map.png)

---

## 4. 更新密码、更新 policy、删除用户

userpass API 把常见运维动作拆成明确端点：读取用户用 `GET /auth/userpass/users/:username`，删除用户用 `DELETE /auth/userpass/users/:username`，更新密码用 `POST /auth/userpass/users/:username/password`，更新 policies 用 `POST /auth/userpass/users/:username/policies`，列出用户用 `LIST /auth/userpass/users`。

这几个端点的含义要分清：更新 password 只改变下一次用用户名密码登录所需的密码；更新 policies 改变后续新登录拿到的 token policies；已经签发出去的 token 仍然按照 token 自身的生命周期和权限生效，除非被显式撤销或过期。

```bash
# 改密码
vault write auth/userpass/users/alice/password password="new-alice-pwd"

# 改 policies
vault write auth/userpass/users/alice/policies token_policies="team-operator"

# 删用户
vault delete auth/userpass/users/alice
```

读取用户配置时，API 返回的是 token 配置类字段，不会返回明文密码；这也是为什么管理员应使用密码管理、轮换流程和审计日志管理 userpass 账号，而不是把它当成普通用户数据库浏览。

---

## 5. 何时适合、何时不适合

从教程和运维实践角度看，`userpass` 更适合低依赖、可控范围的场景：教学环境、实验环境、少量本地管理员账号、临时迁移期间的备用入口。它的优点是直观、启动快、没有外部系统依赖。

它不适合作为大型组织的人类身份主干：因为用户名/密码直接由 Vault auth method 管理，不能自动复用 HR、LDAP、OIDC、MFA、离职禁用等外部身份治理流程。大型组织通常应优先考虑能接入外部身份治理的 auth method，然后只把 userpass 留给少数明确边界的账户。

官方文档还包含 User lockout 相关说明；如果你在生产中启用 userpass，应按组织安全要求一起评估密码策略、失败登录锁定、审计和 token TTL。

---

## 6. 本章实验设计

本章实验会启用 `auth/userpass`，创建 `alice`、`bob`、`Mary` 三个教学用户；用不同 policy 展示登录后 token 权限差异；再通过 API/CLI 验证登录、改密码、改 policy、大小写归一化和删除用户。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-userpass" title="实验：Userpass 认证完整动手——创建用户、登录、改密码、改 policy 与大小写归一化" />

---

## 参考文档

- [Userpass Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/userpass)
- [Userpass Auth Method HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/userpass)