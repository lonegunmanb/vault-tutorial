# 第 4 步：签发 leaf 证书、查看 ca_chain、用 openssl 验证完整信任链

模型见 [3.X §3 + §4 末尾](/ch3-pki)。前三步把 Root + Intermediate + Role 都准备好了；本步真正签出一张可用的服务器证书，并**用第三方工具** `openssl verify` 验证整条信任链。

---

## 4.1 签发一张 leaf 证书并保存所有材料

```bash
vault write -format=json pki_int/issue/example-dot-com \
    common_name="api.example.com" \
    alt_names="www.example.com,api.example.com" \
    ttl=24h > leaf.json

jq -r '.data.certificate' leaf.json > leaf.crt
jq -r '.data.private_key' leaf.json > leaf.key
jq -r '.data.issuing_ca' leaf.json > issuing_ca.crt
jq -r '.data.ca_chain[]' leaf.json > ca_chain.pem
```

> **关键事实**：
> - `private_key` 是**动态生成、随响应一次性返回**——**Vault 不存储该私钥**。如果这次没保存，只能重新申请新证书。
> - `ca_chain` 包含所有上级 issuer，但**不含 Root**（Root 应预装在 OS 信任库里）。
> - 同一次响应里把 leaf、私钥、issuing CA、链全给了你——便于自动化部署。

## 4.2 查看 leaf 证书内容

```bash
openssl x509 -in leaf.crt -noout -subject -issuer -dates -ext subjectAltName,authorityInfoAccess,crlDistributionPoints
```

应该能看到：
- `Subject: CN = api.example.com`
- `Issuer: CN = example.com Intermediate`
- `X509v3 Subject Alternative Name: DNS:www.example.com, DNS:api.example.com`
- `Authority Information Access` 指向 Step 2.5 配的 issuing URL
- `X509v3 CRL Distribution Points` 指向 Step 2.5 配的 CRL URL

## 4.3 用 Root + Intermediate 验证 leaf

构造一个完整的信任 bundle 给 openssl：

```bash
# 把 Root + Intermediate 都当成 trusted CA 传给 openssl
cat root.crt pki_int.crt > trust_bundle.pem

openssl verify -CAfile trust_bundle.pem leaf.crt
```

**期望输出**：`leaf.crt: OK`

## 4.4 反例：只用 Intermediate 验证（Root 缺位）

```bash
openssl verify -CAfile pki_int.crt leaf.crt
```

**期望**：报 `unable to get issuer certificate` 或 `self-signed certificate in certificate chain` 之类——因为 openssl 找不到 Intermediate 的签发者 Root。

## 4.5 反例：只用 Root 验证（缺中间链）

```bash
openssl verify -CAfile root.crt leaf.crt
```

**期望**：报 `unable to get local issuer certificate`——leaf 的 issuer 是 Intermediate，Root 不在它的"上一级"位置。

## 4.6 正确的实战姿势：把链一并部署到服务端

服务端通常需要**同时**部署 leaf + intermediate（不含 root），客户端拿到这两份就能从客户端自带的 Root 出发完整验证：

```bash
cat leaf.crt pki_int.crt > server_fullchain.pem
openssl verify -CAfile root.crt -untrusted pki_int.crt leaf.crt
```

**期望**：`leaf.crt: OK`（`-untrusted` 把中间证书喂给 openssl 但不信任它本身）。

## 4.7 用 lookup 查询签发记录

Vault 把每次签发都存了记录（除非 role 设了 `no_store=true`）：

```bash
SERIAL=$(jq -r '.data.serial_number' leaf.json)
echo "serial: $SERIAL"

vault list pki_int/certs | head
vault read pki_int/cert/$SERIAL
```

> **（工程补充）** 生产高频签发场景常把 role 设为 `no_store=true` + `generate_lease=false`——这样签发请求可以走 Performance Standby（不被转发到 active 节点），但代价是 Vault 不再记录该证书。

---

## ✅ 验收

- [ ] 4.3 `openssl verify` 输出 `OK`
- [ ] 4.4 / 4.5 都失败（缺谁都不行）
- [ ] 4.6 用 `-untrusted` 喂 intermediate 也能 OK
- [ ] `vault list pki_int/certs` 列表里有刚才签发的序列号
