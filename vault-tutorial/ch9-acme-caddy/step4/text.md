# 第 4 步：证书轮转——到期自动续期 + 管理员手动吊销

第 3 步让 Caddy 一次拿到了证书；本步把『证书的整个生命周期』在终端里跑一遍：

- **场景 A — 到期前自动续期**：把签发角色的 `max_ttl` 临时缩到 2 分钟，强制 Caddy 重签一张『短命』证书，等待约 90 秒，亲眼看到 Caddy 在剩余 1/3 寿命前主动续期，新证书的**序列号与有效期**都换了一组。
- **场景 B — 管理员手动吊销**：在 Vault 一侧用 `vault write pki_int/revoke` 吊销当前生效的证书，确认它出现在 CRL 里；然后强制 Caddy 重新走一遍 ACME 三步对话，拿到一张**全新序列号**的证书——而旧序列号永久躺在 CRL 中。

两种触发器走的都是同一套 `newOrder → challenge → finalize` 协议管线，对运维而言**只是一句命令的差别**。

> **教学加速说明**：生产环境里 ACME 客户端的续期检查与 OCSP 巡检都按分钟级周期跑，等待时间相对较长。本步用两个手段把整条链路压到几分钟内完成：（a）把角色 TTL 临时调到 2 分钟，让 Caddy 在 80 秒左右就触发『过 2/3 寿命』续期；（b）必要时清掉 Caddy 数据目录里的 `certificates/` 子目录后重启容器，强制立即重走一次下单流程。两个手段都只压缩等待时间，不改变协议本身。

## 4.1 记录当前证书的『身份证』

后面所有判断都建立在『序列号变了 / 没变』这一观察之上，所以先把当前 in-use 的证书序列号与有效期抓下来：

```bash
echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial -dates
```

预期输出形如：

```
serial=4A3B2C...（一串 16 进制）
notBefore=... GMT
notAfter=... GMT  (约 30 天后)
```

把这串 `serial=` 后面的 16 进制记下来——下面把它叫做 `SN_INITIAL`，可直接用 shell 变量保存：

```bash
SN_INITIAL=$(echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial | cut -d= -f2)
echo "初始证书序列号：$SN_INITIAL"
```

## 4.2 场景 A：到期前的自动续期

**第 1 步**：把签发角色的 `max_ttl` 临时缩到 2 分钟，让下一张签出来的证书寿命极短，便于在课堂上观察续期：

```bash
vault write pki_int/roles/learn \
   issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
   allow_any_name=true \
   max_ttl="2m" \
   no_store=false
```

预期返回 `Success! ...`。

> 注意 `pki_int/roles/learn` 的 `max_ttl` 一改，**之后所有新签的证书** 上限都是 2 分钟；已经签出来的旧证书不会被回收，它们各自还活到自己的 `notAfter`。

**第 2 步**：强制 Caddy 立即丢掉旧的 30 天证书、重新走一遍 ACME 申请。最直接的做法是清掉 Caddy 数据目录并重启容器：

```bash
docker rm -f caddy-server 2>/dev/null
rm -rf /root/caddy_data/caddy
docker run -d \
  --name caddy-server \
  --network host \
  --volume /root/caddy_config/Caddyfile:/etc/caddy/Caddyfile \
  --volume /root/index.html:/usr/share/caddy/index.html \
  --volume /root/caddy_data:/data \
  --rm \
  caddy:2.8
sleep 8
```

确认现在 in-use 的是一张 2 分钟寿命的『短命证书』，且序列号已经与 `SN_INITIAL` 不同：

```bash
SN_SHORT=$(echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial | cut -d= -f2)
echo "短命证书序列号：$SN_SHORT"
echo "与初始证书是否相同：$([ "$SN_SHORT" = "$SN_INITIAL" ] && echo YES || echo NO)"
echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -dates
```

预期：

- `与初始证书是否相同：NO`——确实是新签的一张；
- `notAfter - notBefore` ≈ 2 分钟。

**第 3 步**：等待约 90 秒（短于 2 分钟，但已经过了 2/3 寿命的续期阈值），让 Caddy 自己触发续期：

```bash
echo "等待 Caddy 自动续期（约 90 秒）..."
sleep 90
```

**第 4 步**：再次抓一次当前 in-use 证书的序列号，应当看到它**又变了一次**——这就是 ACME 客户端在剩余 1/3 寿命之前主动重跑三步对话的结果：

```bash
SN_RENEWED=$(echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial | cut -d= -f2)
echo "续期后证书序列号：$SN_RENEWED"
echo "与短命证书是否相同：$([ "$SN_RENEWED" = "$SN_SHORT" ] && echo YES || echo NO)"
docker logs caddy-server 2>&1 | grep -Ei 'renew|certificate obtained' | tail -10
```

预期：

- `与短命证书是否相同：NO`——Caddy 已经悄无声息地把证书换了；
- 日志里能看到一行类似 `"msg":"certificate obtained successfully","identifier":"caddy.local"`（这一行是续期成功后打印的）。

**关键观察**：整个续期过程**没有人手动跑任何命令**，HTTPS 没有掉线一秒。这是 ACME 协议在内部 PKI 上提供的『静默续期』红利的全部含义。

## 4.3 场景 B：管理员手动吊销

接下来把视角切回 Vault 一侧，模拟管理员发现私钥可能泄露、需要立即作废这张证书的场景。

**第 1 步**：先把当前 in-use 证书的序列号转成 Vault 接受的『冒号分隔小写 16 进制』格式（OpenSSL 输出的是连写大写），并通过 `pki_int/cert/<serial>` 验证 Vault 这边确实认得这张证书：

```bash
SN_HEX=$(echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial | cut -d= -f2)
SN_VAULT=$(echo "$SN_HEX" | tr 'A-Z' 'a-z' | sed 's/../&:/g;s/:$//')
echo "OpenSSL 序列号：$SN_HEX"
echo "Vault 序列号：  $SN_VAULT"
vault read pki_int/cert/$SN_VAULT | head -5
```

预期 `vault read` 的输出里至少能看到 `certificate` / `issuer_id` 字段，证明 Vault 这边查得到这张证书的元数据。

**第 2 步**：吊销它：

```bash
vault write pki_int/revoke serial_number="$SN_VAULT"
```

预期返回里出现 `revocation_time` 与 `revocation_time_rfc3339` 两个非空字段——这意味着 Vault 已经把这张证书计入了它维护的 CRL。

**第 3 步**：直接读出 CRL，确认刚才吊销的序列号已经在里面：

```bash
vault read -field=certificate pki_int/issuer/$(vault read -field=default pki_int/config/issuers)/crl/pem \
  | openssl crl -noout -text | grep -A1 -i "revoked certificates" | head -5
vault read -field=certificate pki_int/issuer/$(vault read -field=default pki_int/config/issuers)/crl/pem \
  | openssl crl -noout -text | grep -i "serial number" | head -10
```

预期能在 `Serial Number:` 列表里找到一行就是刚才吊销的 `SN_VAULT`（OpenSSL 打印 CRL 时大小写与冒号分隔可能略有差异，对照看 16 进制内容即可）。

> **此时浏览器 / curl 能立刻发现吗？** 如果客户端开启了 OCSP 检查或 CRL 校验，下一次握手就会发现服务器证书已经被吊销并拒绝连接。Caddy 进程内部维护的 OCSP staple 巡检也会按分钟级周期发现这一变化、自动触发续期。课堂上为了把『让新证书顶上来』压缩到几秒之内，下面直接强制 Caddy 重走一次下单流程。

**第 4 步**：让 Caddy 重新申请一张新证书。最直接的做法仍然是清掉它的数据目录并重启：

```bash
docker rm -f caddy-server 2>/dev/null
rm -rf /root/caddy_data/caddy
docker run -d \
  --name caddy-server \
  --network host \
  --volume /root/caddy_config/Caddyfile:/etc/caddy/Caddyfile \
  --volume /root/index.html:/usr/share/caddy/index.html \
  --volume /root/caddy_data:/data \
  --rm \
  caddy:2.8
sleep 8
```

**第 5 步**：抓一次新证书的序列号，应当与刚才被吊销的 `SN_HEX` **不同**——这是 Vault 全新签出来的一张：

```bash
SN_AFTER_REVOKE=$(echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -serial | cut -d= -f2)
echo "被吊销的证书序列号：$SN_HEX"
echo "重签后的证书序列号：$SN_AFTER_REVOKE"
echo "两者是否相同：$([ "$SN_HEX" = "$SN_AFTER_REVOKE" ] && echo YES || echo NO)"
curl --cacert /root/pki/ca_bundle.pem https://caddy.local/
```

预期：

- `两者是否相同：NO`——管理员一句 `vault write pki_int/revoke` 之后，Caddy 已经把整条 ACME 流水线重新跑了一遍；
- `curl` 输出 `hello world`——HTTPS 服务从外部看仍然是通的，运维全程**没有手工分发任何 PEM 文件**。

**第 6 步**（可选验证）：旧序列号在 CRL 里**不会**因为续签了新证书就消失——它会一直留到自身 `notAfter` 之后才能被 CRL 回收：

```bash
vault read -field=certificate pki_int/issuer/$(vault read -field=default pki_int/config/issuers)/crl/pem \
  | openssl crl -noout -text | grep -i "serial number" | head -5
```

预期仍然能在列表里看到刚才被吊销的那个序列号。这正是 CRL 设计的初衷：**任何一张被吊销过的证书，从被吊销的那一刻起到它本来的有效期结束，都必须在 CRL 上保留可查**。

## 4.4 把角色 TTL 还原（可选清理）

如果接着想做别的实验，把 `pki_int/roles/learn` 的 `max_ttl` 还原回 30 天，避免继续受到 2 分钟短 TTL 的干扰：

```bash
vault write pki_int/roles/learn \
   issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
   allow_any_name=true \
   max_ttl="720h" \
   no_store=false
```

> 这一步只是『恢复实验前的角色配置』，不影响已经签出去的证书，也不能撤销一次吊销操作（吊销在 PKI 协议里是**不可逆**的——这正是 CRL 永远只增不减的原因）。

## 4.5 复盘：刚才到底发生了什么

| 触发器 | 谁主动 | 关键命令 | 结果 |
| --- | --- | --- | --- |
| **过 2/3 寿命** | ACME 客户端（Caddy） | 无（协议自动） | 序列号、有效期都换了一组，HTTPS 不掉线 |
| **管理员手动吊销** | Vault 管理员 | `vault write pki_int/revoke serial_number=<sn>` | 旧序列号进 CRL；Caddy 通过 OCSP staple 巡检 / 强制重启感知后**立即重申新证书**，旧序列号永久留在 CRL 中 |

两种触发器走的都是同一套 `newOrder → challenge → finalize` 协议管线——对运维而言，**全部生命周期管理只是一句命令的差别**。把这条结论与第 3 步『没有任何手工证书操作』叠加，9.4 节正文中关于『把 ACME 引到内部 PKI』的所有承诺都在终端里得到亲手验证。

---

## ✅ 验收

- [ ] §4.1 抓到当前 in-use 证书的初始序列号 `SN_INITIAL` 与有效期
- [ ] §4.2 在 `max_ttl=2m` 之后，重启的 Caddy 拿到了一张寿命 ≈ 2 分钟的『短命证书』，序列号 `SN_SHORT ≠ SN_INITIAL`
- [ ] §4.2 等待 90 秒后再抓证书，序列号 `SN_RENEWED ≠ SN_SHORT`，Caddy 日志里出现新的 `certificate obtained successfully`
- [ ] §4.3 `vault write pki_int/revoke` 返回里包含非空的 `revocation_time`
- [ ] §4.3 从 `pki_int/issuer/.../crl/pem` 读出的 CRL 里能找到刚被吊销的那个序列号
- [ ] §4.3 强制 Caddy 重申之后，新证书序列号 `SN_AFTER_REVOKE ≠ SN_HEX`，且 `curl --cacert ... https://caddy.local/` 仍然返回 `hello world`
