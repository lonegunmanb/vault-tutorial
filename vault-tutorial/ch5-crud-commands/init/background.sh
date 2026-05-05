#!/bin/bash
source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

start_vault_dev

vault secrets enable transit > /dev/null

vault secrets enable pki > /dev/null
vault secrets tune -max-lease-ttl=8760h pki > /dev/null
vault write -format=json pki/root/generate/internal \
  common_name="training.internal" \
  ttl=8760h > /tmp/pki-root.json
vault write pki/roles/example \
  allowed_domains="training.internal" \
  allow_subdomains=true \
  allow_localhost=true \
  max_ttl="72h" > /dev/null

vault write identity/entity name="crud-lab-entity" > /tmp/crud-entity.txt

vault write cubbyhole/prepared note="created during setup" > /dev/null

cd /root
finish_setup
