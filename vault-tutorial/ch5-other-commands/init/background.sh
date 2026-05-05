#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq postgresql-client sshpass openssh-client > /dev/null 2>&1

start_postgres

wait "$INSTALL_VAULT_PID"
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

vault secrets enable database > /dev/null 2>&1 || true

vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@127.0.0.1:5432/postgres?sslmode=disable" \
  allowed_roles=readonly \
  username="root" \
  password="rootpassword" > /dev/null

cat > /root/readonly.sql <<'EOF'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";
EOF

vault write database/roles/readonly \
  db_name=postgresql \
  creation_statements=@/root/readonly.sql \
  default_ttl=2m \
  max_ttl=10m > /dev/null

vault secrets enable -path=ssh-otp ssh > /dev/null 2>&1 || true
vault write ssh-otp/roles/training-otp \
  key_type=otp \
  default_user=vaultlab \
  allowed_users="vaultlab,root,ubuntu,student" \
  cidr_list="127.0.0.1/32,10.0.0.0/8" > /dev/null

vault kv put secret/training/wrapped \
  username="student" \
  password="response-wrapped" \
  purpose="unwrap-demo" > /dev/null

cd /root
finish_setup