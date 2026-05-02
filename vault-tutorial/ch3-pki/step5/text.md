# 第 5 步：多 Issuer 与轮换原语 —— reissuance / cross-sign / default 切换

模型见 [3.X §6](/ch3-pki)。自 Vault 1.11 起，**单个 mount 可以拥有多张 issuer 证书**——这是做证书轮换的基础设施。
本步演示三件事：

1. 给 `pki_int/` 添加第二张 issuer（reissuance：同 subject + 同密钥的新证书）
2. 切换 `default` issuer，观察新签发的 leaf 用哪张 CA
3. cross-sign 概念演示（同 subject + 同公钥，issuer 可不同）

---

## 5.1 看当前 pki_int 的 issuer 列表

```bash
vault list pki_int/issuers
vault read pki_int/config/issuers
```

应当只有一张 issuer，名为 `int-2026`（来自 Step 2）；`config/issuers` 里 `default` 指向它。

## 5.2 在 pki_int 上做一次 reissuance（同 subject + 同密钥）

reissuance = 给同一个 subject 用同一份密钥重新签一张证书（通常 issuer 也是同一个 Root，但有效期延长）。

先取出当前 intermediate 的 key reference：

```bash
KEY_REF=$(vault read -format=json pki_int/issuer/int-2026 | jq -r '.data.key_id')
echo "reusing key: $KEY_REF"
```

用同一密钥生成**新的 CSR**（保留 subject）：

```bash
vault write -format=json pki_int/intermediate/generate/existing \
    key_ref="$KEY_REF" \
    common_name="example.com Intermediate" \
    issuer_name="int-2026-reissue" \
    | tee int_reissue_gen.json | jq '.data.csr | .[0:80] + "..."'

jq -r '.data.csr' int_reissue_gen.json > pki_int_reissue.csr
```

让 Root 签这张新 CSR，TTL 给久一点（模拟到期前提前续签）：

```bash
vault write -format=json pki/root/sign-intermediate \
    csr=@pki_int_reissue.csr \
    format=pem_bundle \
    ttl=43800h | jq -r '.data.certificate' > pki_int_reissue.crt

openssl x509 -in pki_int_reissue.crt -noout -subject -issuer -dates
```

把这张新证书**作为新 issuer 导入**到 `pki_int/`：

```bash
vault write -format=json pki_int/issuers/import/cert \
    pem_bundle=@pki_int_reissue.crt | jq '.data.imported_issuers, .data.imported_keys'

vault list pki_int/issuers
```

应当看到现在有**两张 issuer**——同 subject、同公钥，但 serial 不同（即 reissuance）。

## 5.3 给新 issuer 起名，并把它设为 default

```bash
NEW_ISSUER_ID=$(vault list -format=json pki_int/issuers | jq -r '.[]' | while read id; do
  vault read -format=json pki_int/issuer/$id | jq -r 'select(.data.issuer_name=="" or .data.issuer_name==null) | .data.issuer_id' 2>/dev/null
done | head -1)

# 给它命名（如果还没名字）
vault write pki_int/issuer/$NEW_ISSUER_ID issuer_name="int-2026-v2"

# 切换 default
vault write pki_int/config/issuers default="int-2026-v2"
vault read pki_int/config/issuers
```

## 5.4 验证新签发的 leaf 用了新 issuer

```bash
vault write -field=certificate pki_int/issue/example-dot-com \
    common_name="new.example.com" ttl=24h \
    | openssl x509 -noout -issuer -serial
```

留意 `issuer` 仍是 `CN = example.com Intermediate`（subject 没变），但**它来自新的 issuer**——可以对比新旧 issuer 的 serial：

```bash
vault read -field=certificate pki_int/issuer/int-2026 \
  | openssl x509 -noout -serial
vault read -field=certificate pki_int/issuer/int-2026-v2 \
  | openssl x509 -noout -serial
```

## 5.5 切回旧 issuer 也只是一条命令

```bash
vault write pki_int/config/issuers default="int-2026"
```

> **关键事实**：
> - 多 issuer 共存于同一 mount，**按名字或 ID** 引用；`default` 决定 `pki_int/issue/<role>` 用哪张签。
> - reissuance 后两张 issuer 的 `ca_chain` 仅首项不同（除非被 `manual_chain` 阻止）。
> - **所有现有 leaf 仍然有效**——它们的 issuer 字段已固化在证书里，不会因为 default 切换而失效。

## 5.6 cross-sign 是什么（演示概念，不强求完整跑）

cross-sign = 拿"已有 CA B 的 subject + 公钥"用"另一张 CA A"再签一张证书，让 B 的 leaf 在信任 A 的客户端那边也能验证通过。

> **要求**（来自 [3.X §6](/ch3-pki)）：相同 Subject、相同公钥（key material）；Issuer **可能**不同（may），Serial Number **一定**不同（will）。
>
> 真实生产用途：root 轮换时让新旧 root 互签，过渡期间所有 leaf 都能验证。
>
> **（工程补充）** 完整 cross-sign 流程涉及两个独立的 CA mount，这里 Step 5.2 的 reissuance 已经把"多 issuer + 切 default"的操作面演示清楚；cross-sign 只是把"再签者"换成另一个 CA mount，命令模板与 5.2 类似（也是 `sign-intermediate` + `issuers/import/cert`）。

---

## ✅ 验收

- [ ] `vault list pki_int/issuers` 显示有 **2 张** issuer
- [ ] 5.4 新签的 leaf 用的是新 issuer（serial 与 5.2 后导入的一致）
- [ ] 5.5 切回旧 default 后再签发，issuer 又换回去
- [ ] 你能解释为什么 reissuance 不会让历史 leaf 失效
