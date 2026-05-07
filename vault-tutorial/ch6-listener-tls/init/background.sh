#!/bin/bash
source /root/setup-common.sh

install_vault

# Tools required by this lab: jq for parsing init JSON, openssl for self-signed
# cert generation, sslscan for protocol/cipher verification, curl for HTTP probes.
need_pkgs=()
for pkg in jq openssl sslscan curl; do
  command -v "$pkg" > /dev/null 2>&1 || need_pkgs+=("$pkg")
done
if [ ${#need_pkgs[@]} -gt 0 ]; then
  apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}" > /dev/null 2>&1
fi

mkdir -p /opt/vault/data /etc/vault.d/tls
chmod 700 /opt/vault/data /etc/vault.d/tls

# Baseline: TLS-disabled HTTP-only listener. Step 2 will harden this to HTTPS.
cat > /root/vault.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

default_lease_ttl = "168h"
max_lease_ttl     = "720h"
EOF

# VAULT_ADDR starts as plain HTTP; the student will switch it to HTTPS in step 2.
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

finish_setup
