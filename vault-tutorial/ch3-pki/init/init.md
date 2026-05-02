# 实验：PKI 机密引擎全链路动手

[3.X PKI 机密引擎](/ch3-pki) 把 Root / Intermediate / Role / 签发 / 多 Issuer / 轮换原语整条线讲清楚了。
本实验在 **Dev 模式 Vault** 上把这条线**全部跑一遍**——用 `vault` CLI + `openssl` 验证每一步的结果。

---

## 实验环境

后台脚本会自动准备好：

- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- **openssl**（系统自带）+ **jq**
- 一个工作目录 `/root/pki-lab/`，所有生成的 CSR、PEM、链文件都放这里
- **Vault 上没有任何预置 PKI mount**——你将从 `vault secrets enable pki` 开始亲手搭

---

## 你将亲手验证的事实

1. **TTL 两层收口**：mount `max-lease-ttl` 是全局上限，role `max_ttl` 在其内进一步收紧；二者都会按 should/may 而非 must 截断（实测 role 上限会真的把请求 TTL 截短）
2. **Root CA 私钥永不离开 Vault**（`internal` 模式）；返回的证书是 informational 副本
3. **Root → Intermediate → Leaf 三层链**：CSR 的 `common_name` **只填 CSR subject**，真正能签什么由 role 的 `allowed_domains` 决定
4. **Role 是签发的安检口**：违反 `allowed_domains` / 超过 `max_ttl` 的请求会被 Vault 拒绝（亲手触发 4xx 错误）
5. **`openssl verify`** 用 Root + Intermediate 链能成功验证 leaf 证书
6. **多 Issuer**：同一个 mount 下可有多张 issuer 证书，可按名字 / `default` 切换；reissuance 重发同一 subject + 同一密钥的新证书，`ca_chain` 仅首项不同
7. **签发命令背后都是 HTTP API**：所有 `vault write pki/...` 都对应 `/v1/pki/...` 端点，可在自动化中直接调用

预期耗时：25 ~ 40 分钟。
