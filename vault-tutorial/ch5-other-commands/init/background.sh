#!/bin/bash
set -Eeuo pipefail

SETUP_LOG="/tmp/ch5-other-commands-setup.log"
rm -f /tmp/.setup-done /tmp/.setup-failed "$SETUP_LOG"
exec > >(tee -a "$SETUP_LOG") 2>&1

fail_setup() {
  echo "ERROR: ch5-other-commands setup failed. See $SETUP_LOG for details."
  touch /tmp/.setup-failed
  exit 1
}

trap 'echo "ERROR: setup failed near line $LINENO"; touch /tmp/.setup-failed' ERR

if [ ! -f /root/setup-common.sh ]; then
  echo "ERROR: /root/setup-common.sh is missing. The scenario asset was not copied into the lab host."
  fail_setup
fi

source /root/setup-common.sh

install_lab_packages() {
  if command -v jq > /dev/null 2>&1 \
    && command -v psql > /dev/null 2>&1 \
    && command -v sshpass > /dev/null 2>&1 \
    && command -v ssh > /dev/null 2>&1 \
    && command -v unzip > /dev/null 2>&1; then
    echo "Client tools and prerequisites are already installed."
    return 0
  fi

  for attempt in 1 2; do
    echo "Installing client tools and prerequisites, attempt $attempt/2..."
    if timeout 45s env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=30 \
        -o Acquire::Retries=3 \
        update -qq \
      && timeout 90s env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=30 \
        -o Acquire::Retries=3 \
        install -y -qq jq postgresql-client sshpass openssh-client unzip; then
      return 0
    fi
    if [ "$attempt" != "2" ]; then
      echo "Client tool installation failed on attempt $attempt; retrying in 5 seconds..."
      sleep 5
    fi
  done
  echo "ERROR: failed to install jq, postgresql-client, sshpass, openssh-client and unzip."
  return 1
}

echo "Installing client tools and prerequisites..."
install_lab_packages

if ! command -v docker > /dev/null 2>&1; then
  echo "ERROR: docker is not available, but this lab needs a local PostgreSQL container for lease exercises."
  fail_setup
fi

echo "Installing Vault and pulling PostgreSQL image..."
install_vault &
INSTALL_VAULT_PID=$!
timeout 240s docker pull postgres:16 > /dev/null &
PULL_POSTGRES_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$PULL_POSTGRES_PID"

echo "Starting PostgreSQL database..."
start_postgres

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
echo "ch5-other-commands setup complete."