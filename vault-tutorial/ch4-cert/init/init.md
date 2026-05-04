# 实验：TLS 证书认证完整动手

[4.7 TLS 证书认证](/ch4-cert) 讲的是“客户端在 TLS 握手里出示证书，Vault 按可信 CA 与 role 约束签发 token”。本实验会生成真实证书材料，并用 HTTPS Vault listener 跑通 `auth/cert/login`。

---

## 实验环境

后台脚本会准备好：

- TLS 模式 Vault，地址 `https://127.0.0.1:8200`
- Vault 服务端 TLS CA：`/root/cert-lab/server-ca.crt`
- 客户端认证 CA：`/root/cert-lab/client-ca.crt`
- 成功样例客户端证书：`web-client.crt/key`，DNS SAN 为 `web-01.example.org`，OU 为 `platform`
- 约束不匹配证书：`db-client.crt/key`，DNS SAN 为 `db-01.example.org`，OU 为 `database`
- 不受信 CA 签发证书：`rogue-client.crt/key`

CLI 中的 `-ca-cert` 会使用 `server-ca.crt` 验证 Vault 服务端证书；写入 `auth/cert/certs/web` 的 `certificate` 会使用 `client-ca.crt` 验证客户端证书。

---

## 你将亲手验证的事实

1. `cert` auth 必须运行在能接收客户端证书的 TLS listener 上。
2. 客户端证书登录时，私钥不上传给 Vault；它只用于 TLS 握手证明“我持有这张证书对应的私钥”。
3. CA 可信只是第一关，`allowed_dns_sans`、`allowed_organizational_units` 等 role 约束还会继续收紧允许登录的证书。
4. `name=web` 会让登录请求只匹配 `web` 这个证书 role。

预期耗时：15 ~ 20 分钟。