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

install_jq() {
  if command -v jq > /dev/null 2>&1; then
    echo "jq is already installed."
    return 0
  fi

  echo "Installing jq standalone binary..."
  if curl --connect-timeout 10 --max-time 60 -fsSL \
      "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" \
      -o /usr/local/bin/jq \
      && chmod +x /usr/local/bin/jq \
      && jq --version; then
    return 0
  fi

  local apt_log="/tmp/ch5-other-commands-apt.log"
  rm -f "$apt_log"

  echo "Standalone jq download failed; installing jq with apt..."
  if timeout 90s env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=45 \
        -o Acquire::Retries=3 \
        install -y -qq --no-install-recommends jq >> "$apt_log" 2>&1; then
    return 0
  fi

  echo "Direct jq install failed; refreshing apt metadata and retrying once..."
  if timeout 90s env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=45 \
        -o Acquire::Retries=3 \
        update -qq >> "$apt_log" 2>&1 \
      && timeout 90s env DEBIAN_FRONTEND=noninteractive apt-get \
        -o DPkg::Lock::Timeout=45 \
        -o Acquire::Retries=3 \
        install -y -qq --no-install-recommends jq >> "$apt_log" 2>&1; then
    return 0
  fi

  echo "apt could not install jq; recent apt log follows:"
  tail -40 "$apt_log" 2>/dev/null || true
  return 1
}

install_vault_for_lab() {
  if command -v vault > /dev/null 2>&1 \
     && vault version 2>/dev/null | grep -q "v${VAULT_VERSION}"; then
    echo "vault ${VAULT_VERSION} already installed, skipping download."
    return 0
  fi

  if command -v unzip > /dev/null 2>&1; then
    install_vault
    return 0
  fi

  if command -v python3 > /dev/null 2>&1; then
    echo "Installing Vault with Python zip extraction..."
    curl --connect-timeout 10 --max-time 120 -fsSL \
      "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" \
      -o /tmp/vault.zip
    python3 - <<'PY'
import zipfile

with zipfile.ZipFile('/tmp/vault.zip') as archive:
    archive.extract('vault', '/usr/local/bin')
PY
    chmod +x /usr/local/bin/vault
    rm -f /tmp/vault.zip
    vault version
    return 0
  fi

  echo "ERROR: neither unzip nor python3 is available to extract Vault."
  return 1
}

ensure_vault_ssh_client_tools() {
  if ! command -v ssh > /dev/null 2>&1; then
    echo "Installing OpenSSH client for vault ssh..."
    timeout 120s env DEBIAN_FRONTEND=noninteractive apt-get \
      -o DPkg::Lock::Timeout=45 \
      -o Acquire::Retries=3 \
      update -qq
    timeout 120s env DEBIAN_FRONTEND=noninteractive apt-get \
      -o DPkg::Lock::Timeout=45 \
      -o Acquire::Retries=3 \
      install -y -qq --no-install-recommends openssh-client
  fi

  if command -v sshpass > /dev/null 2>&1; then
    echo "sshpass is already available."
    return 0
  fi

  echo "Installing sshpass-compatible helper for vault ssh OTP automation..."
  cat > /usr/local/bin/sshpass <<'EOF'
#!/bin/sh
case "$1" in
  -p)
    password=$2
    shift 2
    ;;
  -p*)
    password=${1#-p}
    shift
    ;;
  *)
    echo "sshpass compatibility wrapper supports only -p PASSWORD" >&2
    exit 2
    ;;
esac

askpass=$(mktemp /tmp/vault-sshpass.XXXXXX) || exit 1
trap 'rm -f "$askpass"' EXIT INT TERM
cat > "$askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$SSHPASS_PASSWORD"
ASKPASS
chmod 700 "$askpass"

SSHPASS_PASSWORD=$password
export SSHPASS_PASSWORD
if command -v setsid > /dev/null 2>&1; then
  exec setsid env SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" "$@"
fi
exec env SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" "$@"
EOF
  chmod +x /usr/local/bin/sshpass
}

ensure_postgres_readonly_role() {
  local pg_log="/tmp/ch5-other-commands-pg-role.log"

  echo "Ensuring PostgreSQL read-only role exists..."
  for attempt in 1 2 3 4 5; do
    if docker exec -i learn-postgres psql -U root -d postgres -v ON_ERROR_STOP=1 <<'SQL' > "$pg_log" 2>&1
DO
$do$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ro') THEN
    CREATE ROLE ro NOINHERIT;
  END IF;
END
$do$;
GRANT USAGE ON SCHEMA public TO ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ro;
SQL
    then
      echo "PostgreSQL read-only role is ready."
      return 0
    fi

    echo "Read-only role setup failed on attempt $attempt; retrying in 2 seconds..."
    sleep 2
  done

  echo "ERROR: failed to prepare PostgreSQL read-only role; recent psql log follows:"
  tail -40 "$pg_log" 2>/dev/null || true
  return 1
}

if ! command -v docker > /dev/null 2>&1; then
  echo "ERROR: docker is not available, but this lab needs a local PostgreSQL container for lease exercises."
  fail_setup
fi

echo "Preparing jq, Vault and container images..."
install_jq &
INSTALL_JQ_PID=$!
install_vault_for_lab &
INSTALL_VAULT_PID=$!
timeout 240s docker pull postgres:16 > /dev/null &
PULL_POSTGRES_PID=$!
timeout 240s docker pull ghcr.io/lonegunmanb/vault-tutorial-otp-ssh-ubuntu:latest > /dev/null &
PULL_OTP_IMAGE_PID=$!

wait "$INSTALL_JQ_PID"
wait "$INSTALL_VAULT_PID"
wait "$PULL_POSTGRES_PID"
wait "$PULL_OTP_IMAGE_PID"

ensure_vault_ssh_client_tools

echo "Starting PostgreSQL database..."
start_postgres
ensure_postgres_readonly_role

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
  cidr_list="127.0.0.1/32,10.0.0.0/8,172.16.0.0/12" > /dev/null

vault kv put secret/training/wrapped \
  username="student" \
  password="response-wrapped" \
  purpose="unwrap-demo" > /dev/null

cd /root
finish_setup
echo "ch5-other-commands setup complete."