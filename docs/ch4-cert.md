---
order: 46
title: 4.7 TLS 证书认证：用客户端证书登录 Vault
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.7 TLS 证书认证：用客户端证书登录 Vault

> **核心结论**：TLS 证书认证方法（`cert`）让调用方在与 Vault 建立 TLS 连接时出示客户端证书；Vault 先通过 TLS 层拿到这张证书，再用 `auth/cert/certs/<name>` 中配置的可信 CA 或可信证书与一组约束进行匹配，匹配成功后签发 Vault token。它不是“把证书文件作为普通表单参数上传给 Vault”，而是依赖 TLS 连接本身携带客户端证书。

参考：
- [TLS Certificates Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/cert)
- [TLS Certificate Auth API](https://developer.hashicorp.com/vault/api-docs/auth/cert)
- [Vault TCP Listener Parameters](https://developer.hashicorp.com/vault/docs/configuration/listener/tcp)
- [Killercoda Creator Documentation](https://killercoda.com/creators)

---

## 1. cert 认证在 Vault 体系里的位置

回到 [4.1 章](/ch4-auth-basic) 的分类框架，`cert` 属于凭据型认证方法：外部凭据是一张 TLS 客户端证书及其私钥，Vault 验证证书链和 role 约束后，输出的仍然是一枚 Vault token。

TLS 客户端证书必须适合做客户端认证：官方文档说明，证书的 Extended Key Usage 需要包含 `ClientAuth` 或 `Any`；可信 CA 或可信证书直接配置到 auth method 的 `certs/` 路径下，`cert` 方法不能从外部来源自动读取可信证书清单。

![cert 认证：把客户端证书换成 Vault token](/images/ch4-cert/cert-auth-flow.png)

> 绘图提示词：手绘风格，现实事物比喻风格，彩色横向流程图。画一个客户端带着“客户端证书 + 私钥”来到 Vault 玻璃门，玻璃门上写“TLS 握手”；Vault 门卫先看证书是不是由已登记 CA 签发，再看证书上的 DNS SAN、OU、扩展用途是否命中 role 清单，最后递出“Vault token 临时通行证”。气泡方向必须明确：客户端气泡尾巴连到客户端，指向 Vault 门卫，台词“我在 TLS 握手里出示客户端证书”；Vault 门卫气泡尾巴连到证书登记册，台词“这张证书的 CA 和约束匹配吗？”；证书登记册指向 Vault，回答“匹配 web role”；Vault 指向客户端说“给你 web-read token”。

---

## 2. TLS listener 是前提

官方文档特别强调，使用 `cert` auth 时，Vault 配置中的 `tls_disable` 和 `tls_disable_client_certs` 都必须为 false，因为客户端证书是在 TLS 通信过程中传给 Vault 的。

这句话的实际含义是：如果 Vault 只以明文 HTTP 运行，或者 TLS listener 明确不接收客户端证书，那么 `auth/cert/login` 端点就拿不到客户端证书，自然无法完成证书认证。

CLI 示例里的 `-ca-cert` 或 curl 示例里的 `--cacert` 指的是“验证 Vault 服务端 TLS 证书的 CA”，不是签发客户端证书的 CA；签发客户端证书的 CA 是写入 `auth/cert/certs/<name>` 的 `certificate` 字段，用来让 cert auth method 判断客户端证书是否可信。

---

## 3. trusted certificate role：CA、约束与 policy

`vault write auth/cert/certs/web ...` 会创建一个名为 `web` 的证书 role。这个 role 至少要包含 `certificate`，也就是用于验证客户端证书的 PEM 格式 CA 证书或可信证书；还可以配置 `display_name`、`token_policies`、`token_ttl` 等 token 参数。

role 还能限制证书主题和扩展：`allowed_common_names` 限制 Common Name，`allowed_dns_sans` 限制 DNS SAN，`allowed_email_sans` 限制 Email SAN，`allowed_uri_sans` 限制 URI SAN，`allowed_organizational_units` 限制 OU，`required_extensions` 要求特定自定义扩展存在并匹配模式。

官方 API 文档还提醒，如果证书包含 DNS SAN，登录时会验证这些 DNS SAN；如果要求验证 Common Name，Common Name 应是完全限定域名，并且应同时作为 DNS SAN 出现在证书中。

![cert role：证书登记册上的多重检查](/images/ch4-cert/cert-role-constraints.png)

---

## 4. 登录时的 name 参数

登录端点是 `POST /auth/cert/login`。客户端通过 TLS 连接出示证书，并可在请求体中提供 `name`，要求 Vault 只 against 这一个证书 role 认证；如果不提供 `name`，auth method 会尝试所有受信证书配置，返回任意一个匹配结果。

CLI 示例中，客户端写成 `vault login -method=cert -client-cert=cert.pem -client-key=key.pem name=web`；API 示例中，客户端使用 `curl --cert cert.pem --key key.pem --data '{"name":"web"}' https://.../v1/auth/cert/login`。

这种设计让同一个 `auth/cert` mount 可以登记多个证书 role，例如 `web`、`batch`、`admin`；客户端明确提供 `name` 时，排障也更容易，因为你知道它正在匹配哪一份 role 约束。官方文档还说明，cert role 名称和 CRL 名称会被归一为小写，所以教学和生产配置都建议统一使用小写命名。

---

## 5. 撤销检查：CRL 与 OCSP

cert auth 支持撤销检查。管理员可以在 `auth/cert/crls/<name>` 下提交 PEM 格式 CRL，也可以配置可信的 CRL distribution point URL，让 Vault 按需获取 CRL。

有 CRL 时，Vault 会在客户端认证时检查证书链里的序列号；如果客户端提供的任意证书链中没有证书序列号命中撤销列表，则允许继续认证；如果客户端提供的所有链都命中撤销序列号，则拒绝认证。

官方文档特别说明，CRL 匹配按“序列号”进行；由于 RFC 只要求同一个 CA 内序列号唯一，而不是全世界唯一，如果多个 CA 的序列号空间可能冲突，官方建议把不同 CA/CRL 拆到多个 cert auth mount 中。

除了 CRL，cert auth 也可以启用 OCSP；启用后，Vault 会查询证书中指定或 auth method 中配置的 OCSP server 来判断证书撤销状态。

---

## 6. 反向代理与负载均衡边界

如果 Vault 前面有反向代理或负载均衡器，并且 TLS 在代理层终止，那么 Vault 本身看不到原始 TLS 握手里的客户端证书；这种场景需要代理把已经验证过的客户端证书通过 header 转交给 Vault，并在 Vault listener stanza 中配置对应 header 名称。

这种模式的安全性不再只取决于 Vault，还取决于代理是否确实完整验证了客户端 TLS 证书，以及代理到 Vault 之间的连接是否受保护；官方建议这段连接最好也使用 mTLS。

---

## 7. 生产使用时的边界条件

cert auth 的优势是客户端私钥不需要上传给 Vault；Vault 只在登录时看到 TLS 层提交的证书，并按 role 约束签发 token。实践上，如果团队已经有证书签发、分发和轮换流程，它会更容易纳入现有机器身份或设备身份体系。

但它也要求客户端私钥被妥善保护；一旦私钥泄露，攻击者就可以带着证书和私钥尝试登录 Vault，直到证书过期、被 CRL/OCSP 撤销，或对应 cert role 被删除/收紧。

如果组织没有现成 PKI、证书分发和撤销机制，`cert` auth 的运维复杂度会主要落在证书生命周期管理上；反过来，如果组织已经把机器身份、设备身份或人类证书纳入统一 PKI，`cert` auth 就能复用这套身份基础设施。

---

## 7.1 标准配置流程速记

把 §3 / §4 的 CLI 调用串成最小可跑的端到端示例——启用插件、登记客户端 CA role、用客户端证书登录：

```bash
# 1. 启用 cert 认证方法（默认挂在 auth/cert/）
vault auth enable cert

# 2. 登记 web role：把客户端 CA 写入 certificate，并按 DNS SAN / OU 收紧约束
vault write auth/cert/certs/web \
    display_name=web \
    certificate=@/root/cert-lab/client-ca.crt \
    allowed_dns_sans="web-*.example.org" \
    allowed_organizational_units="platform" \
    token_policies="web-read" \
    token_ttl="15m"

# 3. 用客户端证书登录（TLS 握手中提交证书）
vault login \
    -method=cert \
    -ca-cert=/root/cert-lab/server-ca.crt \
    -client-cert=/root/cert-lab/web-client.crt \
    -client-key=/root/cert-lab/web-client.key \
    name=web
```

等价的 HTTP API 调用（登录端点）。客户端证书必须通过 TLS 握手提交，因此 `--cert` / `--key` 由 curl 在握手层送出，请求体只携带 role `name`：

```bash
curl --request POST \
     --cacert /root/cert-lab/server-ca.crt \
     --cert /root/cert-lab/web-client.crt \
     --key /root/cert-lab/web-client.key \
     --data '{"name":"web"}' \
     "$VAULT_ADDR/v1/auth/cert/login"
```

返回 JSON 的 `auth.client_token` 即为新签发的 Vault token；如果不传 `name`，Vault 会尝试所有受信证书 role 中任意一个匹配项。

---

## 8. 本章实验设计

本章实验会在 Killercoda Ubuntu 环境中生成两套 CA：一套用于 Vault HTTPS listener 的服务端证书，另一套用于签发客户端认证证书；然后以 TLS 模式启动 Vault，启用 `auth/cert`，登记客户端 CA role，最后用 `vault login -method=cert` 和 `curl --cert --key` 完成真实证书登录。

实验还会生成一个不符合 role 约束的客户端证书和一个不受信 CA 签发的客户端证书，用它们演示“证书链可信”和“role 约束命中”是两道不同的检查。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch4-cert" title="实验：TLS 证书认证完整动手——HTTPS Vault、客户端证书、role 约束与失败验证" />

---

## 参考文档

- [TLS Certificates Auth Method — Vault Docs](https://developer.hashicorp.com/vault/docs/auth/cert)
- [TLS Certificate Auth API](https://developer.hashicorp.com/vault/api-docs/auth/cert)
- [Vault TCP Listener Parameters](https://developer.hashicorp.com/vault/docs/configuration/listener/tcp)
- [Killercoda Creator Documentation](https://killercoda.com/creators)