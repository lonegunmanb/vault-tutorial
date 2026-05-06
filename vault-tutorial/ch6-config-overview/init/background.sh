#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

mkdir -p /opt/vault/data
chmod 700 /opt/vault/data

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

# Persist VAULT_ADDR for all future shells (Vault is NOT yet started; the
# student will start it manually in step 2).
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

finish_setup
