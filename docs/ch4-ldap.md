---
order: 45
title: 4.6 LDAP 认证：让目录用户用账号密码登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.6 LDAP 认证：让目录用户用账号密码登录 Vault

> **核心结论**：LDAP 认证方法（`ldap`）让组织既有的 LDAP / Active Directory 用户使用自己的目录账号密码登录 Vault；Vault 在登录时连接 LDAP，确认用户名和密码确实能完成目录认证，再把 LDAP 用户、LDAP 组以及 Vault 本地 `users/`、`groups/` 映射到一组 Vault policy，最终签发 Vault token。它的本质不是让 Vault 托管 LDAP 账号，而是把“目录账号密码”转换为“受 Vault policy 约束的 Vault token”。

参考：
- [LDAP Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/ldap)
- [LDAP Auth API](https://developer.hashicorp.com/vault/api-docs/auth/ldap)
- [OpenLDAP Administrator's Guide — Quick-Start](https://www.openldap.org/doc/admin26/quickstart.html)
- [OpenLDAP Administrator's Guide — Schema Specification](https://www.openldap.org/doc/admin26/schema.html)
- [Killercoda Creator Documentation](https://killercoda.com/creators)

---

## 1. LDAP 认证在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 的分类框架，LDAP 认证方法属于“用户/口令型”认证：调用者通常是人类用户，提交的是 LDAP 用户名和密码；Vault 验证通过后签发的是 Vault token，而不是把 LDAP 密码继续传给机密引擎使用。

这和 [3.10 章 LDAP 机密引擎](/ch3-ldap) 是相反方向：LDAP 认证方法是“LDAP 用户 → Vault”，用于登录；LDAP 机密引擎是“Vault → LDAP”，用于轮转、创建或借出目录账号密码。二者都连接 LDAP，但一个解决“谁能进 Vault”，另一个解决“Vault 如何管理 LDAP 凭据”。

![LDAP 认证方法与 LDAP 机密引擎方向对比](/images/ch4-ldap/ldap-auth-vs-secrets-engine.png)

---

## 2. 基本术语：DN、Bind、Search Base、Filter

DN（Distinguished Name，专有名称）是 LDAP 条目的完整地址，例如 `uid=alice,ou=People,dc=example,dc=org`；它像档案柜里一张员工档案的完整抽屉路径，而不仅是登录时输入的短用户名 `alice`。

Bind 是 LDAP 中“拿某个 DN 和密码进行认证”的动作；Vault 配置 LDAP auth 时常见的 `binddn` / `bindpass` 是给 Vault 用来搜索用户和组的查询账号，而用户登录时提交的密码会被用来验证用户自己的 LDAP 身份。

Search Base 是搜索起点；`userdn` 指定 Vault 到哪里找用户对象，`groupdn` 指定 Vault 到哪里找组对象。Filter 是搜索条件；`userfilter` 用来把登录用户名筛成一个用户对象，`groupfilter` 用来找出这个用户属于哪些 LDAP 组。

---

## 3. 一次 LDAP 登录的数据流

一次典型 LDAP 登录可以理解为五步：用户把 `username` 和 `password` 交给 Vault；Vault 用配置好的搜索方式找到该用户的 DN；Vault 用用户 DN 和用户密码向 LDAP 执行 bind 来证明密码正确；Vault 查询该用户属于哪些 LDAP 组；Vault 把命中的 LDAP 组和 Vault 本地用户映射转换成 policy，并签发 Vault token。

![LDAP 登录流程手绘示意](/images/ch4-ldap/ldap-auth-login-flow.png)

CLI 登录可以使用 `vault login -method=ldap username=mitchellh`，API 登录则是向 `/v1/auth/ldap/login/:username` 提交包含 `password` 的请求体；响应中的 `auth.client_token` 是后续访问 Vault 的凭据，metadata 中会包含用户名。

---

## 4. 配置连接：LDAP 地址、TLS 与证书

LDAP auth 必须预先启用并配置；默认挂载路径是 `auth/ldap/`，启用命令是 `vault auth enable ldap`，配置端点是 `auth/ldap/config`。

连接层最重要的字段是 `url`，它可以是 `ldap://host:389`、`ldaps://host:636`，也可以是逗号分隔的多个 URL；多个 URL 会按顺序尝试，常用于主备 LDAP 服务器或多域控制器场景。

如果使用 `ldap://` 明文端口但 LDAP 服务器支持 StartTLS，可以设置 `starttls=true` 让连接建立后升级为加密通道；如果使用 `ldaps://` 或 StartTLS，就应提供合适的 CA 证书或依赖系统信任库，`insecure_tls=true` 会跳过证书校验，官方把它标记为不安全选项，应谨慎使用。

Vault 可以从操作系统证书信任库读取 LDAP 证书；如果证书在 Vault 启动后才加入系统信任库，需要重启 Vault，LDAP 插件才能在新连接中使用这些证书信息。

---

## 5. 找到用户：authenticated search、anonymous search 与 UPN

Vault 支持多种用户定位方式。最常见的是 authenticated search：配置 `binddn` 与 `bindpass`，让 Vault 先用这个查询账号在 `userdn` 下搜索用户对象，再用找到的用户 DN 和登录密码进行认证。

如果目录允许匿名搜索，也可以设置 `discoverdn=true`，让 Vault 通过 anonymous bind 查找用户 DN；这种方式减少了查询账号配置，但是否可用取决于 LDAP 服务器的匿名访问策略。

Active Directory 场景还可以使用 `upndomain`，让用户以 `username@example.com` 这类 UPN 形式登录；当 `upndomain` 存在时，Vault 也提供 `enable_samaccountname_login` 选项，让 AD 用户可用 `sAMAccountName` 或 `userPrincipalName` 登录。

`userfilter` 是一个 Go template，默认相当于 `(&#123;&#123;.UserAttr&#125;&#125;=&#123;&#123;.Username&#125;&#125;)`；它可以用来附加限制，例如排除某类外包账号，但官方 API 文档提醒，过滤器中应包含 `&#123;&#123;.UserAttr&#125;&#125;` 或与 `userattr` 对应的字面字段，以便搜索结果仍然唯一并避免登录 alias 映射冲突。

---

## 6. 找到组：groupfilter、groupdn、groupattr

用户密码通过验证后，Vault 还需要解析“这个用户属于哪些 LDAP 组”。官方文档把组成员解析概括成两类策略：一种是从用户对象属性追踪到组，另一种是在组对象里搜索是否包含该用户；Vault 的 `groupfilter`、`groupdn`、`groupattr` 就是为这一步服务的。

默认 `groupfilter` 会同时尝试 `memberUid=&#123;&#123;.Username&#125;&#125;`、`member=&#123;&#123;.UserDN&#125;&#125;`、`uniqueMember=&#123;&#123;.UserDN&#125;&#125;`，以兼容多种常见目录 schema；如果目录使用 OpenLDAP 的 `groupOfNames`，常见写法是搜索组对象并检查 `member=&#123;&#123;.UserDN&#125;&#125;`。

`groupattr` 指定从搜索结果中取哪个属性当作组名；当 `groupfilter` 返回组对象时通常使用 `cn`，当查询返回用户对象并从 `memberOf` 属性取组时则可以使用 `memberOf`。

![LDAP 组到 Vault policy 映射示意](/images/ch4-ldap/ldap-group-policy-map.png)

---

## 7. Policy 映射：LDAP group、Vault user 与 token 创建时刻

LDAP auth 的 policy 映射不是直接写在 LDAP 服务器里，而是写在 Vault 的 `auth/ldap/groups/<group>` 与 `auth/ldap/users/<username>` 路径中；例如 `vault write auth/ldap/groups/scientists policies=foo,bar` 会把 LDAP 组 `scientists` 映射到 Vault policy `foo` 与 `bar`。

Vault 也允许在 `auth/ldap/users/<username>` 上给单个用户附加 policy，或把某个用户加入额外的 Vault 本地组；这类映射是 Vault 侧补充授权，不要求 LDAP 目录中真的存在同名组对象。

官方文档特别提醒，用户到 policy 的映射发生在 token 创建时；LDAP 组成员关系或 Vault 映射变化不会自动改变已经签发出去的旧 token，想让新权限生效，需要吊销旧 token 并让用户重新登录。

---

## 8. DN 转义与用户名安全

官方文档强调，管理员需要自己保证配置中的 DN 被正确转义，包括 `userdn`、用于搜索的 `binddn` 等；LDAP auth 只会在登录用户名被插入最终 bind DN 时按 RFC 4514 规则进行用户名转义。

Active Directory 的转义规则与 RFC 4514 略有差异，例如 `#` 和 `=` 的处理存在额外要求；如果 AD 用户名可能包含这些字符，管理员需要按 AD 自身规则额外处理，不能假设 Vault 会替所有配置项自动修正。

这类细节听起来琐碎，但它影响的是“Vault 到底在 LDAP 里查到了谁”；一旦 DN 或过滤器写错，结果可能是登录失败，也可能是在复杂目录里匹配到意外对象。因此生产配置应优先使用唯一、稳定、明确的 `userattr` 与 `userfilter`。

---

## 9. 生产使用时的边界条件

LDAP auth 适合人类用户使用既有目录账号登录 Vault；应用和工作负载一般更适合使用 AppRole、Kubernetes、AWS、JWT/OIDC 等非人类身份方法，因为把 LDAP 用户密码放进应用配置会扩大长效口令泄露面。

生产环境应尽量使用 LDAPS 或 StartTLS，并使用受信 CA 验证 LDAP 服务器证书；只有在明确的临时实验或排障场景下才应考虑 `insecure_tls=true`。

`binddn` 应当是只具备搜索用户和组所需权限的低权限账号，而不是目录管理员账号；虽然官方文档只要求它能执行用户和组搜索，但从最小权限原则看，它不应拥有修改密码、创建用户或删除条目的能力。

---

## 10. 本章实验设计

本章实验使用一个本地 OpenLDAP 容器作为目录服务，并预置 `alice`、`bob`、`carol` 三个用户与 `dev`、`ops`、`contractors` 三个组；这样可以在没有企业 AD 的环境里真实跑通 LDAP bind、用户搜索、组搜索和 policy 映射。

实验会依次完成：启用 `auth/ldap` 并配置 authenticated search；把 LDAP 组 `dev`、`ops` 映射到 Vault policy 并用 Alice/Bob 登录验证；演示 Vault 本地 user 映射只对新 token 生效；最后用 `userfilter` 拦截 `employeeType=Contractor` 的 Carol，并清理实验环境。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-ldap" title="实验：LDAP 认证完整动手——OpenLDAP、组映射、用户映射与 userfilter" />

---

## 参考文档

- [LDAP Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/ldap)
- [LDAP Auth API](https://developer.hashicorp.com/vault/api-docs/auth/ldap)
- [OpenLDAP Administrator's Guide — Quick-Start](https://www.openldap.org/doc/admin26/quickstart.html)
- [OpenLDAP Administrator's Guide — Schema Specification](https://www.openldap.org/doc/admin26/schema.html)
- [Killercoda Creator Documentation](https://killercoda.com/creators)