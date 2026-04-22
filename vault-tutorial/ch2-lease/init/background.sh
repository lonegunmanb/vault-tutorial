#!/bin/bash
# Background setup — runs before the user sees the terminal.
# We pre-bootstrap Vault + Postgres + database engine + readonly role
# so the learner can focus purely on lease semantics.

source /root/setup-common.sh

install_vault
start_vault_dev
start_postgres

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# Enable database secrets engine and configure the postgres connection.
vault secrets enable database > /dev/null 2>&1 || true

vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@localhost:5432/postgres?sslmode=disable" \
  allowed_roles=readonly \
  username="root" \
  password="rootpassword" > /dev/null

# SQL template for dynamic users.
cat > /root/readonly.sql <<'EOF'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";
EOF

# default_ttl=1m + max_ttl=5m — short on purpose, so the learner can see
# both the renewal floor and the hard ceiling within minutes.
vault write database/roles/readonly \
  db_name=postgresql \
  creation_statements=@/root/readonly.sql \
  default_ttl=1m \
  max_ttl=5m > /dev/null

# An "app" policy that can read dynamic creds AND renew/revoke its own leases.
vault policy write app - <<'EOF'
path "database/creds/readonly" {
  capabilities = ["read"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
EOF

finish_setup
