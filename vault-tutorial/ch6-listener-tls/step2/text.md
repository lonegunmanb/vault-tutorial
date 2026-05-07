# 第二步：生成自签 ECDSA 证书并启用 TLS

本步骤生成一份仅用于教学的自签 ECDSA 证书，并把 listener 从 `tls_disable = true` 升级为带 `tls_cert_file` / `tls_key_file` 的 HTTPS。

> 在生产环境你应当使用受信任的内部 CA（例如第 3.7 节 PKI 引擎）签发证书，而不是自签证书。这里采用自签只是为了让本实验完全离线、可复现。

## 2.1 生成自签 ECDSA 证书与私钥

使用 OpenSSL 一次性生成 P-256 私钥与对应的自签证书，并在 SAN 中明确把 `127.0.0.1` 与 `localhost` 都列入：

```bash
cat > /etc/vault.d/tls/openssl.cnf <<'EOF'
[ req ]
distinguished_name = req
prompt             = no
x509_extensions    = v3_ca

[ req ]
CN = vault-classroom

[ v3_ca ]
basicConstraints     = CA:FALSE
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth
subjectAltName       = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1  = 127.0.0.1
EOF

openssl ecparam -name prime256v1 -genkey -noout \
  -out /etc/vault.d/tls/vault.key

openssl req -new -x509 -days 30 \
  -key   /etc/vault.d/tls/vault.key \
  -out   /etc/vault.d/tls/vault.crt \
  -config /etc/vault.d/tls/openssl.cnf \
  -extensions v3_ca \
  -subj "/CN=vault-classroom"

chmod 600 /etc/vault.d/tls/vault.key
ls -l /etc/vault.d/tls/
openssl x509 -in /etc/vault.d/tls/vault.crt -noout -subject -issuer -dates -ext subjectAltName
```

## 2.2 修改 listener，删除 tls_disable，启用 TLS

```bash
cat > /root/vault.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "https://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address       = "127.0.0.1:8200"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/vault.d/tls/vault.key"
}

default_lease_ttl = "168h"
max_lease_ttl     = "720h"
EOF
```

## 2.3 重启 Vault 使新 listener 生效

> 注意：从 HTTP 升级到 HTTPS 属于"协议级"变更，不在 SIGHUP 可热加载的范围内（参见教程 6.2 节第 5 节"关于 SIGHUP 与 TLS 配置热加载的边界"）。这里必须重启进程。

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
```

启动后 Vault 仍然处于 sealed 状态（raft 数据目录尚在，但每次重启都需要重新解封）：

```bash
export VAULT_ADDR='https://127.0.0.1:8200'
export VAULT_CACERT=/etc/vault.d/tls/vault.crt
export UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init.json)
export VAULT_TOKEN=$(jq -r '.root_token' /root/init.json)

vault operator unseal "$UNSEAL_KEY"
vault status
```

> 把 `VAULT_ADDR` 改成 `https://...` 并设置 `VAULT_CACERT` 是必须的：CLI 会用它来验证服务器证书。生产环境如果使用受信任 CA 签发的证书，并且系统 CA 信任链已包含该 CA，则无需 `VAULT_CACERT`。

把 HTTPS 与 CACERT 持久化到 shell：

```bash
sed -i 's|http://127.0.0.1:8200|https://127.0.0.1:8200|' /etc/profile.d/vault.sh
echo 'export VAULT_CACERT=/etc/vault.d/tls/vault.crt' >> /etc/profile.d/vault.sh
```

用 `curl` 实测 HTTPS 工作正常：

```bash
curl -s --cacert /etc/vault.d/tls/vault.crt \
  https://127.0.0.1:8200/v1/sys/health | jq .
```

进一步证明：去掉 `--cacert` 会触发证书校验失败（这是预期行为，因为是自签证书）：

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' https://127.0.0.1:8200/v1/sys/health || true
echo "（上一行如果显示 curl 错误，是预期的——自签证书无法被系统 CA 验证）"
```

到这里你已经把 listener 从默认禁用 TLS 升级为带证书的 HTTPS；下一步会把允许的 TLS 版本进一步收紧到只剩 1.3。
