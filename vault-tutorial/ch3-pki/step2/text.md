# 第 2 步：启用 pki_int/、生成 Intermediate CSR、Root 签发、set-signed

模型见 [3.X §4](/ch3-pki)。生产中 Root CA 通常**离线保管**，只用来签 Intermediate，再让 Intermediate 在线签 leaf。
本实验用同一个 Vault 模拟"两台 CA"：`pki/` 当 Root，`pki_int/` 当 Intermediate。

---

## 2.1 启用第二个 PKI mount

```bash
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int     # Intermediate 5 年
vault secrets list | grep -E "Path|pki"
```

> Intermediate 的 max TTL **应（should）** ≤ Root CA 的 TTL。**（编者注）** 否则 Root 一过期 Intermediate 也失效，验证时会信任链断裂。

## 2.2 在 pki_int 生成 Intermediate CSR

```bash
vault write -format=json pki_int/intermediate/generate/internal \
    common_name="example.com Intermediate" \
    issuer_name="int-2026" \
    | tee int_gen.json | jq '.data.csr | .[0:80] + "..."'

jq -r '.data.csr' int_gen.json > pki_int.csr
openssl req -in pki_int.csr -noout -subject -verify
```

> 这一步**只生成 CSR + 内部私钥**——还不是证书。**关键**：`common_name` 这里只填 CSR 的 subject；真正能签什么由 Intermediate 上的 role 的 `allowed_domains` 决定（Step 3 验证）。

## 2.3 用 Root CA 签 Intermediate CSR

```bash
vault write -format=json pki/root/sign-intermediate \
    csr=@pki_int.csr \
    format=pem_bundle \
    ttl=43800h | tee int_signed.json | jq '.data | keys'
```

把签好的证书写出来：

```bash
jq -r '.data.certificate' int_signed.json > pki_int.crt
openssl x509 -in pki_int.crt -noout -subject -issuer -dates
```

> **（编者注）** `format=pem_bundle` 返回适合导入/传递的 PEM bundle；是否包含上级 CA 取决于签发 CA 类型，原文未展开。本实验里我们只用 `.data.certificate` 字段——是 signed intermediate 自身。

## 2.4 把签好的证书写回 Intermediate mount

```bash
vault write pki_int/intermediate/set-signed certificate=@pki_int.crt
```

`set-signed` 之后，Intermediate 才"上岗"——它现在拥有：自己生成的私钥（在 Vault 内部）+ Root 签发的证书。

## 2.5 给 Intermediate mount 也配置 URL

```bash
vault write pki_int/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki_int/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki_int/crl"
```

## 2.6 验证 Intermediate 的 ca_chain

```bash
curl -s http://127.0.0.1:8200/v1/pki_int/ca_chain | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
  | openssl pkcs7 -print_certs -noout 2>/dev/null \
  || curl -s http://127.0.0.1:8200/v1/pki_int/ca_chain | grep -c "BEGIN CERTIFICATE"
```

> ca_chain 端点返回所有上级 issuer，但**不含 Root**（Root 应预装在 OS 信任库里）——本实验里只看到 1 张（intermediate 自己），符合官方说法。

---

## ✅ 验收

- [ ] `vault secrets list` 同时看到 `pki/` 和 `pki_int/`
- [ ] `openssl x509 -in pki_int.crt -noout -issuer` 显示 issuer = `CN = example.com Root`
- [ ] `vault read pki_int/cert/ca` 返回的是同一张 intermediate 证书
- [ ] CSR、签发、set-signed 三步**顺序不能乱**——若先做 set-signed 再签发会报错
