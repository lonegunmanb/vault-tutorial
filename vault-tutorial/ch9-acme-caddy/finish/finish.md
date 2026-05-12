# 恭喜完成 PKI + ACME 实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | Caddy 在 `auto_https off` 配置下只监听 :80；`curl http://caddy.local/` 通、`curl https://caddy.local/` 立即 `Connection refused`——建立了清晰的对照基线 |
| **Step 2** | 用一键脚本搭好两级 PKI；用 3 条命令在 `pki_int/` 上启用 ACME（`secrets tune` 放头 + `config/acme enabled=true`）；`curl http://127.0.0.1:8200/v1/pki_int/acme/directory` 看到符合 RFC 8555 的 directory JSON |
| **Step 3** | 仅改 Caddyfile（加一行 `acme_ca`），重启 Caddy，**无任何手工证书操作**；`curl --cacert ... https://caddy.local/` 拿到 hello world；`openssl x509` 看到证书 issuer 是 `learn.internal Intermediate Authority`、有效期 30 天、SAN 含 `caddy.local` |

## ACME 心智速记

```
┌──────────────┐   ① newOrder (申请为 caddy.local 签证书)
│   Caddy      │ ──────────────────────────────────────►   ┌──────────────┐
│ (ACME 客户端) │                                            │  Vault PKI    │
│   :80 / :443 │  ② "请把 token <X> 放到 .well-known/..."  │  (ACME 服务器  │
└──────────────┘ ◄──────────────────────────────────────── │   = pki_int/) │
       │                                                    └──────────────┘
       │  ③ 在本机 :80 准备好 /.well-known/acme-challenge/<X>     ▲
       │                                                          │
       │  ④ ◄── HTTP GET /.well-known/acme-challenge/<X> ────────┤  Vault 主动回访
       │  ⑤ ──── 200 OK + token <X> ──────────────────────────► │
       │                                                          │
       │  ⑥ finalize (提交 CSR) ────────────────────────────────► │
       │  ⑦ ◄────── 颁发的 X.509 证书 ─────────────────────────── │
       ▼
   把私钥与证书写到 /data/caddy/certificates/...
   监听 :443 对外提供 HTTPS
   寿命过 2/3 时再跑一遍 ① ~ ⑦ 自动续期
```

## 把这套思路放回真实工程

- **客户端换成什么都行**：本节选 Caddy 因为它『默认即自动 HTTPS』。生产里更常见的搭配是 [Traefik](https://doc.traefik.io/traefik/) 直接配 ACME resolver、或 Kubernetes 上用 [cert-manager](https://cert-manager.io/) 配一个 `ClusterIssuer`，资源对象 `Certificate` 一旦创建，cert-manager 就替集群里所有需要证书的 Ingress / Service 自动跑同一套 ACME 流水线。
- **生产级 TTL 选多短合适？** 业界主流共识是 24 小时到 7 天之间。短到极致后，Vault 的负载会上升（每个客户端每天甚至每小时都续期一次），需要给 ACME 速率限流（[9.1 节](/ch9-production-hardening)）与适度的水平扩容做配套。
- **谁能为哪些域名申请证书？** 本实验为求简洁用了 `allow_any_name=true`。生产里必须把 `pki_int/roles/<role>` 的 `allowed_domains` 收紧（例如只允许 `*.svc.example.com`），并叠加 ACME 的 EAB（External Account Binding，[Vault ACME EAB 文档](https://developer.hashicorp.com/vault/api-docs/secret/pki#acme-external-account-bindings)）让客户端必须先用一个预共享的 Key ID + HMAC 把账号注册到 Vault 才能申请——彻底封堵『谁都能伪造客户端去申请证书』的攻击面。
- **审计与可见性**：[8 章](/ch8-audit-overview) 的审计日志会记录每一次 ACME 协议端点的调用主体；建议生产部署一定要打开 file 或 syslog 审计设备，便于事后排查『谁在何时申请了什么域名的证书』。

## 清理

实验环境会随 Killercoda 容器一起销毁，无需手动清理；如果想在课堂上重置：

```bash
docker stop caddy-server 2>/dev/null
vault secrets disable pki_int
vault secrets disable pki
rm -rf /root/caddy_data/caddy /root/pki/root_2024_ca.crt \
       /root/pki/pki_intermediate.csr /root/pki/intermediate.cert.pem
```
