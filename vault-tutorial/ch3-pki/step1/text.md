# 第 1 步：启用 pki/、tune max-lease-ttl、生成 Root CA

模型见 [3.X §2 + §3](/ch3-pki)。本步要：

1. 启用一个挂载在 `pki/` 路径的 PKI 引擎
2. 把 mount 的 `max-lease-ttl` 调到 10 年（Root CA 需要长 TTL）
3. 用 `pki/root/generate/internal` 生成自签 Root CA（私钥**永不离开 Vault**）
4. 配置 issuing/CRL URL（这些会被编码进将来签发的证书）

---

## 1.1 启用 PKI 引擎

```bash
vault secrets enable pki
vault secrets list | grep -E "Path|pki"
```

> 默认挂载路径 = engine 名（`pki/`）。**（编者注）** 后面 step2 我们会再用 `-path=pki_int` 启用第二个 PKI 实例当 Intermediate。

## 1.2 调高 max-lease-ttl

```bash
vault secrets tune -max-lease-ttl=87600h pki
```

> mount 默认 `max-lease-ttl` 仅 30 天；Root CA 通常希望 10 年。**注意**：role 级 `max_ttl` 只能比 mount 上限**更短**（在 Step 3 会亲手验证）。

## 1.3 生成自签 Root CA

```bash
vault write -format=json pki/root/generate/internal \
    common_name="example.com Root" \
    issuer_name="root-2026" \
    ttl=87600h | tee root_gen.json | jq '.data | {issuer_id, issuer_name, certificate: (.certificate | .[0:80] + "...")}'
```

把证书单独存出来，方便后面用 `openssl` 验证：

```bash
jq -r '.data.certificate' root_gen.json > root.crt
openssl x509 -in root.crt -noout -subject -issuer -dates
```

> **关键事实**：
> - `internal` 模式下生成的私钥**只在 Vault 内部**——返回的 JSON 里**没有** `private_key` 字段，自己 `grep private_key root_gen.json` 验证一下。
> - `issuer_name="root-2026"` 给这个 issuer 起一个人类可读的名字，方便 Step 5 多 issuer 时按名字引用。

```bash
grep -c private_key root_gen.json   # 期望: 0
```

## 1.4 配置 issuing/CRL URL

这两个 URL 会被编码进将来签发的每张证书的扩展字段（AIA / CRL Distribution Points），客户端按这些 URL 取 CA 链与吊销列表。

```bash
vault write pki/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
```

> **（工程补充）** 实验环境用 `127.0.0.1`；生产应换成客户端可达的 FQDN（域名或 LB），且**已签发证书的 URL 不会随配置更新而改变**——尽早设对。

## 1.5 读取 CA 证书（任何人可读，无需 token）

```bash
curl -s http://127.0.0.1:8200/v1/pki/ca/pem | head -3
curl -s http://127.0.0.1:8200/v1/pki/ca/pem | openssl x509 -noout -subject
```

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `pki/`（type=pki）
- [ ] `openssl x509 -in root.crt -noout -subject` 输出包含 `CN = example.com Root`
- [ ] `grep -c private_key root_gen.json` 输出 `0`（私钥不会回显）
- [ ] `curl /v1/pki/ca/pem` 返回的就是 root.crt 同一张证书
