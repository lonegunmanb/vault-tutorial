#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-common.sh — shared setup functions for Killercoda scenarios
#
# This file is the SINGLE SOURCE OF TRUTH for common setup logic.
# It is copied into each scenario's assets/ directory by:
#   npm run sync-setup  (or automatically via prebuild)
#
# Usage in background.sh:
#   source /root/setup-common.sh
#   install_vault
#   finish_setup
# ─────────────────────────────────────────────────────────

VAULT_VERSION="${VAULT_VERSION:-1.19.2}"

install_vault() {
  if ! command -v unzip > /dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq unzip > /dev/null 2>&1
  fi

  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" \
    -o /tmp/vault.zip \
    && unzip -o -q /tmp/vault.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/vault \
    && rm -f /tmp/vault.zip

  vault version || echo "WARNING: vault install failed"
}

start_vault_dev() {
  # Start Vault in dev mode (in-memory, no TLS, root token = root)
  export VAULT_ADDR='http://127.0.0.1:8200'
  export VAULT_TOKEN='root'

  vault server -dev -dev-root-token-id=root \
    -dev-listen-address=0.0.0.0:8200 \
    > /var/log/vault-dev.log 2>&1 &

  echo "Waiting for Vault dev server to be ready..."
  for i in $(seq 1 30); do
    if vault status > /dev/null 2>&1; then
      echo "Vault is ready."
      return 0
    fi
    sleep 1
  done
  echo "WARNING: Vault did not become healthy within 30 seconds"
  cat /var/log/vault-dev.log
}

start_postgres() {
  # Start a Postgres container for dynamic-secret demos.
  # Image: postgres:16. Superuser: root / rootpassword. Listens on 5432.
  if ! command -v docker > /dev/null 2>&1; then
    echo "WARNING: docker not available, cannot start postgres"
    return 1
  fi

  docker rm -f learn-postgres > /dev/null 2>&1 || true
  docker run -d \
    --name learn-postgres \
    -e POSTGRES_USER=root \
    -e POSTGRES_PASSWORD=rootpassword \
    -p 5432:5432 \
    --rm \
    postgres:16 > /dev/null

  echo "Waiting for Postgres to be ready..."
  for i in $(seq 1 60); do
    if docker exec learn-postgres pg_isready -U root > /dev/null 2>&1; then
      echo "Postgres is ready."
      # Create the read-only role that dynamic users will inherit from.
      docker exec -i learn-postgres psql -U root -c \
        "CREATE ROLE \"ro\" NOINHERIT;" > /dev/null 2>&1 || true
      docker exec -i learn-postgres psql -U root -c \
        "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"ro\";" > /dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
  echo "WARNING: Postgres did not become healthy within 60 seconds"
  docker logs learn-postgres || true
}

finish_setup() {
  touch /tmp/.setup-done
}
