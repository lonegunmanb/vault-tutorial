# 第 3 步：Role 收口 —— allowed_domains / allow_subdomains / max_ttl 拒签验证

模型见 [3.X §2.5](/ch3-pki)。Role 是 PKI 的"安检口"——它把"谁能签什么样的证书"硬编码成策略。
本步**亲手触发**几个被 Vault 拒绝的请求，体会 role 的边界究竟在哪里。

---

## 3.1 创建一个严格收口的 role

```bash
vault write pki_int/roles/example-dot-com \
    allowed_domains="example.com" \
    allow_subdomains=true \
    max_ttl=72h
```

> 三个参数：
> - `allowed_domains=example.com`：白名单域名
> - `allow_subdomains=true`：允许 `foo.example.com`、`bar.example.com`、`a.b.example.com` 这类子域
> - `max_ttl=72h`：role 级 TTL 上限（Step 4 会亲手验证它真的会截短请求 TTL）

## 3.2 ✅ 合法请求：example.com 子域

```bash
vault write -format=json pki_int/issue/example-dot-com \
    common_name="api.example.com" \
    ttl=24h | jq '.data | {certificate, private_key, issuing_ca, ca_chain, serial_number, expiration}'
```

应当看到 `certificate` / `private_key` / `issuing_ca` / `ca_chain` / `serial_number` / `expiration` 六个字段都有值——前四个是 PEM 文本（多行 `-----BEGIN .../-----END ...`），后两个是元数据。

## 3.3 ❌ 拒签 1：CN 不在 allowed_domains

```bash
vault write pki_int/issue/example-dot-com \
    common_name="api.evil.com" \
    ttl=24h
```

**期望**：返回类似 `* common name api.evil.com not allowed by this role` 的错误，**不会**签出任何证书。

## 3.4 ❌ 拒签 2：CN 是顶级域但 allow_subdomains 限制下顶级也得显式允许

```bash
vault write pki_int/issue/example-dot-com \
    common_name="example.com" \
    ttl=24h
```

> **（编者注）** 默认情况下 `allow_subdomains=true` **不**自动允许裸域 `example.com` 本身——若也要签裸域得加 `allow_bare_domains=true`。**实测**这一条会成功还是失败取决于 Vault 版本对 "the CN itself matches an allowed domain" 的处理；亲手跑一次看你这版的行为。

## 3.5 ⚠️ 截断 1：超出 max_ttl 的请求会被截到 72h

```bash
vault write -format=json pki_int/issue/example-dot-com \
    common_name="long-lived.example.com" \
    ttl=720h | jq '.data.expiration' \
    && echo "expiration is in unix seconds; convert: $(jq -r '.data.expiration' <<< $(vault write -format=json pki_int/issue/example-dot-com common_name=long-lived.example.com ttl=720h))"
```

更直观地：

```bash
vault write -field=certificate pki_int/issue/example-dot-com \
    common_name="long-lived.example.com" \
    ttl=720h \
    | openssl x509 -noout -dates
```

**期望**：`notAfter` ≈ 现在 + 72 小时，而**不是** 720 小时——role 的 `max_ttl` 把请求**截短**了，不是报错。

## 3.6 ❌ 拒签 3：违反 allowed_domains 的 SAN

```bash
vault write pki_int/issue/example-dot-com \
    common_name="api.example.com" \
    alt_names="api.evil.com,api.example.com" \
    ttl=24h
```

**期望**：报错——SAN 中含 evil.com 同样过不了 role 的白名单。

## 3.7 复盘：role 字段速查

```bash
vault read pki_int/roles/example-dot-com
```

注意你**没有**显式设置的字段（如 `allow_ip_sans`、`allow_wildcard_certificates`、`key_type`、`key_bits`）也都有默认值——生产中按需收口。

---

## ✅ 验收

- [ ] 3.2 成功签出，返回 serial_number
- [ ] 3.3 报 `common name ... not allowed by this role`
- [ ] 3.5 签出的证书 `notAfter - notBefore ≈ 72h`，**不是** 720h
- [ ] 3.6 同样被 role 拦下
