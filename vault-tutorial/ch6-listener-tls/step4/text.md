# 第四步：用 SIGHUP 验证 TLS 协议版本不可热加载

教程 6.2 节第 5 节明确指出：`tls_cert_file` 与 `tls_key_file` **所对应文件的内容**可以通过 SIGHUP 热加载（用于证书轮换），但 `tls_min_version` / `tls_max_version` / `tls_cipher_suites` 等其它 TLS 配置项**必须重启进程**才会生效。本步骤亲手验证这一边界。

## 4.1 把 `tls_min_version` 改回 `"tls12"`，但只发 SIGHUP，不重启

```bash
sed -i 's|tls_min_version = "tls13"|tls_min_version = "tls12"|' /root/vault.hcl
grep tls_min_version /root/vault.hcl
```

发送 SIGHUP（注意：**不是** SIGTERM；进程不会重启）：

```bash
kill -HUP "$(cat /tmp/vault.pid)"
sleep 1
ps -p "$(cat /tmp/vault.pid)" -o pid,etime,cmd
```

确认进程还是同一个 PID。现在再扫描一次：

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

**关键观察**：尽管配置文件已经写成 `tls_min_version = "tls12"`，扫描结果里 `TLSv1.2` 仍然是 `disabled`。这印证了：协议版本的修改不在 SIGHUP 热加载的范围内。

```bash
echo "--- TLS 1.2 仍然被拒绝（即便配置文件改成了 tls12）---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.2 --tlsv1.2 \
  https://127.0.0.1:8200/v1/sys/health || echo "TLS 1.2 握手仍被拒绝"
```

## 4.2 真正重启进程，让修改生效

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

再次扫描：

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

现在 `TLSv1.2` 应该恢复为 `enabled`。

## 4.3 反过来证明：证书文件内容确实可以 SIGHUP 热加载

下面的脚本把当前证书改名备份，再用同一份私钥签出一份**新有效期**的证书，写回原路径，发送 SIGHUP。Vault 应当读取新证书而不需要重启：

```bash
# 备份旧证书
cp /etc/vault.d/tls/vault.crt /etc/vault.d/tls/vault.crt.bak

# 用相同私钥重新签发：把 days 改成 365
openssl req -new -x509 -days 365 \
  -key   /etc/vault.d/tls/vault.key \
  -out   /etc/vault.d/tls/vault.crt \
  -config /etc/vault.d/tls/openssl.cnf \
  -extensions v3_ca \
  -subj "/CN=vault-classroom"

echo "--- 新旧证书有效期对比 ---"
echo "旧:" ; openssl x509 -in /etc/vault.d/tls/vault.crt.bak -noout -dates
echo "新:" ; openssl x509 -in /etc/vault.d/tls/vault.crt    -noout -dates

# SIGHUP 触发证书重载
kill -HUP "$(cat /tmp/vault.pid)"
sleep 1
```

用 `openssl s_client` 直接看 listener 当前对外出示的证书有效期：

```bash
echo | openssl s_client -connect 127.0.0.1:8200 -servername localhost 2>/dev/null \
  | openssl x509 -noout -dates
```

应当显示新的 365 天有效期。这印证了：**证书文件的内容可以通过 SIGHUP 热重载**，对应教程中 `tls_cert_file` 字段标注的 `reloads-on-SIGHUP`。

到这里你已经亲身体验了 SIGHUP 在 TLS 配置上的精确边界。
