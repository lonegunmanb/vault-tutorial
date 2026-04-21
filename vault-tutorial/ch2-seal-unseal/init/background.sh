#!/bin/bash
# Background setup — runs before the user sees the terminal.
# We pre-bootstrap the Vault server (start + init + unseal + seed data)
# so the learner can focus on threshold observation, rotate and rekey.

source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Prepare workspace and storage dir
mkdir -p /root/workspace/shares
mkdir -p /opt/vault/data
chmod 700 /opt/vault/data

# Write the HCL config (a faithful, minimal production-ish file)
cat > /etc/vault.hcl <<'EOF'
ui = true
disable_mlock = true

storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

api_addr = "http://127.0.0.1:8200"
EOF

# Start vault in the background
nohup vault server -config=/etc/vault.hcl > /tmp/vault.log 2>&1 &

export VAULT_ADDR='http://127.0.0.1:8200'

# Wait for the listener to be reachable (rc=2 means sealed-but-up, that's fine)
for i in $(seq 1 30); do
  vault status > /dev/null 2>&1
  rc=$?
  if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
    break
  fi
  sleep 1
done

# Init with 5/3 Shamir
vault operator init -key-shares=5 -key-threshold=3 -format=json \
  > /root/workspace/init.json

# Extract shares + root token to individual files (mode 600)
for i in 0 1 2 3 4; do
  jq -r ".unseal_keys_b64[$i]" /root/workspace/init.json \
    > /root/workspace/shares/share-$((i+1)).key
done
jq -r '.root_token' /root/workspace/init.json > /root/workspace/root.token
chmod 600 /root/workspace/shares/*.key /root/workspace/root.token

# Unseal with the first 3 shares
for i in 1 2 3; do
  vault operator unseal "$(cat /root/workspace/shares/share-$i.key)" > /dev/null
done

# Login and seed two demo secrets
export VAULT_TOKEN="$(cat /root/workspace/root.token)"
vault secrets enable -version=2 -path=secret kv > /dev/null 2>&1 || true
vault kv put secret/seal-demo \
  scenario="real-vault-not-dev" \
  storage="file-backend" > /dev/null
vault kv put secret/before-rotate \
  message="this-was-encrypted-with-DEK-term-1" > /dev/null

# Persist env vars for the learner's interactive shell
cat >> /root/.bashrc <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="$(cat /root/workspace/root.token)"
EOF

cd /root/workspace
finish_setup
