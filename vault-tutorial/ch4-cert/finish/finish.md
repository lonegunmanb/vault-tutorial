# 恭喜完成 TLS 证书认证实验！

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| Step 1 | cert auth 依赖 HTTPS listener 接收客户端证书；服务端 CA 和客户端 CA 用途不同。 |
| Step 2 | `auth/cert/certs/web` 同时登记客户端 CA、证书约束和登录后获得的 policy。 |
| Step 3 | 客户端可以用 `vault login -method=cert` 或 API 通过 TLS 客户端证书换取 Vault token。 |
| Step 4 | CA 可信但 SAN/OU 不匹配会失败；名称像 web 但 CA 不受信也会失败。 |

## 两个最容易混的 CA

```text
server-ca.crt -> 客户端用它验证“我连到的 Vault 服务端是真的”
client-ca.crt -> Vault cert auth 用它验证“客户端证书是受信 CA 签的”
```

CLI 里的 `-ca-cert` 和 curl 里的 `--cacert` 指的是第一种；`vault write auth/cert/certs/web certificate=@...` 写入的是第二种。

**返回文档**：[4.7 TLS 证书认证](/ch4-cert)