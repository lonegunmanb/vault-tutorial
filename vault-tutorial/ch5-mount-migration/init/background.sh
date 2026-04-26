#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Start Vault in dev mode
start_vault_dev

# Wait for Vault to be ready
wait_vault_ready

# --- Seed data: KV engine at default path with several secrets ---
vault kv put secret/app-team-a/db host="db.prod.internal" port="5432" password="s3cret-A"
vault kv put secret/app-team-a/api-key key="ak_live_xxxxxxxxxxxx"
vault kv put secret/app-team-b/cache host="redis.prod.internal" password="r3dis-B"

# --- Seed data: a second KV engine at a custom path ---
vault secrets enable -path=legacy-kv -version=2 kv
vault kv put legacy-kv/old-service token="tok_legacy_12345"

# --- Seed data: enable userpass auth at default path with a test user ---
vault auth enable userpass
vault write auth/userpass/users/alice password="training" policies="app-team-a-read"

# --- Seed data: enable a second userpass at a custom path ---
vault auth enable -path=old-login userpass
vault write auth/old-login/users/bob password="training" policies="default"

# --- Create a policy that references the current paths ---
vault policy write app-team-a-read - <<'EOF'
path "secret/data/app-team-a/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/app-team-a/*" {
  capabilities = ["read", "list"]
}
EOF

cd /root
finish_setup
