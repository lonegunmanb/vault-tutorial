# 第四步：通过 SIGHUP 验证 TLS 协议版本不可热加载

教程 6.2 节第 5 节明确指出：`tls_cert_file` 与 `tls_key_file` **所对应文件的内容**可通过 SIGHUP 热加载（用于证书轮换），但 `tls_min_version` / `tls_max_version` / `tls_cipher_suites` 等其它 TLS 配置项**必须重启进程**才会生效。本步骤将通过实际操作验证这一边界。

## 4.1 将 `tls_min_version` 改回 `"tls12"`，但仅发送 SIGHUP，不重启进程

```bash
sed -i 's|tls_min_version = "tls13"|tls_min_version = "tls12"|' /root/vault.hcl
grep tls_min_version /root/vault.hcl
```

发送 SIGHUP（注意：**并非** SIGTERM；进程不会重启）：

```bash
kill -HUP "$(cat /tmp/vault.pid)"
sleep 1
ps -p "$(cat /tmp/vault.pid)" -o pid,etime,cmd
```

确认进程仍保持同一 PID。再次执行扫描：

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

**关键观察**：尽管配置文件已写为 `tls_min_version = "tls12"`，扫描结果中 `TLSv1.2` 仍为 `disabled`。这印证了：协议版本的修改不在 SIGHUP 热加载的范围内。

```bash
echo "--- TLS 1.2 仍被拒绝（即使配置文件已改为 tls12）---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.2 --tlsv1.2 \
  https://127.0.0.1:8200/v1/sys/health || echo "TLS 1.2 握手仍被拒绝"
```

## 4.2 重启进程使修改生效

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

再次执行扫描：

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

此时 `TLSv1.2` 应恢复为 `enabled`。

## 4.3 反向验证：证书文件内容确实可被 SIGHUP 热加载

下列脚本将当前证书重命名为备份文件，再使用同一份私钥签发一份**具有新有效期**的证书并写回原路径，随后发送 SIGHUP。Vault 应在不重启的情况下读取到新证书：

```bash
# 备份旧证书
cp /etc/vault.d/tls/vault.crt /etc/vault.d/tls/vault.crt.bak

# 使用相同私钥重新签发：将 days 设为 365
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

通过 `openssl s_client` 直接查看 listener 当前对外出示的证书有效期：

```bash
echo | openssl s_client -connect 127.0.0.1:8200 -servername localhost 2>/dev/null \
  | openssl x509 -noout -dates
```

应显示新的 365 天有效期。这印证了：**证书文件的内容可通过 SIGHUP 热重载**，对应教程中 `tls_cert_file` 字段标注的 `reloads-on-SIGHUP`。

至此，你已通过实际操作验证了 SIGHUP 在 TLS 配置上的精确边界。
