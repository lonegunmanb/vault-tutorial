# 第三步：将 TLS 收紧至仅允许 TLS 1.3

第 2 步启用 TLS 后，listener 默认允许 TLS 1.2 与 TLS 1.3 同时存在；这是 Vault 的开箱行为。本步骤将把 listener 收紧至**仅接受 TLS 1.3**，并使用 `sslscan` 进行客观验证。

## 3.1 验证当前状态：TLS 1.2 与 TLS 1.3 均处于启用状态

首先通过 `sslscan` 查看当前实际协商出的协议范围：

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

预期可观察到 `TLSv1.2` 与 `TLSv1.3` 均为 `enabled`，而 `SSLv2`、`SSLv3`、`TLSv1.0`、`TLSv1.1` 均为 `disabled`——这正是教程 6.2 节第 4 节所阐述的"Vault 默认即拒绝 TLS 1.0/1.1"。

另以 `curl` 强制不同协议进行握手以做交叉验证：

```bash
echo "--- 尝试 TLS 1.3 ---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.3 --tlsv1.3 \
  https://127.0.0.1:8200/v1/sys/health

echo "--- 尝试 TLS 1.2 ---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.2 --tlsv1.2 \
  https://127.0.0.1:8200/v1/sys/health

echo "--- 尝试 TLS 1.1（预期失败）---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.1 --tlsv1.0 \
  https://127.0.0.1:8200/v1/sys/health || echo "TLS 1.1 握手被拒绝（预期行为）"
```

## 3.2 修改配置：tls_min_version = "tls13"

```bash
sed -i 's|tls_key_file  = "/etc/vault.d/tls/vault.key"|tls_key_file    = "/etc/vault.d/tls/vault.key"\n  tls_min_version = "tls13"|' /root/vault.hcl
grep -A 5 'listener "tcp"' /root/vault.hcl
```

## 3.3 重启 Vault（不能 SIGHUP，参见教程 6.2 节第 5 节）

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

## 3.4 再次扫描：仅余 TLS 1.3

```bash
sslscan --no-colour 127.0.0.1:8200 | sed -n '/SSL\/TLS Protocols:/,/^$/p'
```

预期输出中 `TLSv1.2` 已变为 `disabled`，仅 `TLSv1.3` 仍为 `enabled`。

`curl` 同样应反映这一变化：

```bash
echo "--- TLS 1.3 仍然可用 ---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tlsv1.3 \
  https://127.0.0.1:8200/v1/sys/health

echo "--- TLS 1.2 现在应被拒绝 ---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/vault.d/tls/vault.crt --tls-max 1.2 --tlsv1.2 \
  https://127.0.0.1:8200/v1/sys/health || echo "TLS 1.2 握手被拒绝（预期行为）"
```

至此，你已将 listener 收紧至"TLS 1.3 唯一可用"——这正是教程 6.2 节给出的最高强度基线之一。
