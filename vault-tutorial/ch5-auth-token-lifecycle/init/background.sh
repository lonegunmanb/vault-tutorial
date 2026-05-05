#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

start_vault_dev

vault kv put secret/app/config username="demo-app" password="training-password" > /dev/null

cat > /root/app-read.hcl <<'EOF'
path "secret/data/app/config" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

vault policy write app-read /root/app-read.hcl > /dev/null

cd /root
finish_setup
