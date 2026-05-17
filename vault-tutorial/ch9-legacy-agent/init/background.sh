#!/bin/bash
set +e

if [ ! -f /root/setup-common.sh ]; then
  echo "ERROR: /root/setup-common.sh not found. Did sync-setup copy scenario assets?" >&2
  exit 1
fi

source /root/setup-common.sh

CONSUL_TEMPLATE_VERSION="${CONSUL_TEMPLATE_VERSION:-0.39.1}"
LAB_DIR="/root/legacy-lab"

# ─────────────────────────────────────────────────────────
# Install apt packages SERIALLY first (avoid dpkg lock contention
# with background installers that may also apt-install unzip).
# ─────────────────────────────────────────────────────────
apt-get update -qq && apt-get install -y -qq \
  jq curl unzip ca-certificates postgresql-client > /dev/null 2>&1

if ! command -v docker > /dev/null 2>&1; then
  apt-get install -y -qq docker.io > /dev/null 2>&1
fi

# ─────────────────────────────────────────────────────────
# install_consul_template: pull the official linux_amd64 binary.
# ─────────────────────────────────────────────────────────
install_consul_template() {
  if command -v consul-template > /dev/null 2>&1 \
     && consul-template -v 2>&1 | grep -q "v${CONSUL_TEMPLATE_VERSION}"; then
    echo "consul-template ${CONSUL_TEMPLATE_VERSION} already installed."
    return 0
  fi
  curl --connect-timeout 10 --max-time 180 -fsSL \
    "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.zip" \
    -o /tmp/consul-template.zip \
    && unzip -o -q /tmp/consul-template.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/consul-template \
    && rm -f /tmp/consul-template.zip
  consul-template -v 2>&1 | head -1 || echo "WARNING: consul-template install failed"
}

# Run independent installs in parallel.
install_vault &
INSTALL_VAULT_PID=$!
install_consul_template &
INSTALL_CT_PID=$!
docker pull postgres:16 > /dev/null 2>&1 &
PULL_PG_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_CT_PID" 2>/dev/null
wait "$PULL_PG_PID" 2>/dev/null

start_vault_dev
start_postgres

# ─────────────────────────────────────────────────────────
# Reseed the `ro` role to be defensive: setup-common may have
# created it on a fresh container, but we want to be sure.
# ─────────────────────────────────────────────────────────
for i in $(seq 1 10); do
  if docker exec -i learn-postgres psql -U root -d postgres \
        -c "DO \$\$ BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='ro') THEN
                CREATE ROLE \"ro\" NOINHERIT;
              END IF;
            END \$\$;" > /dev/null 2>&1; then
    docker exec -i learn-postgres psql -U root -d postgres \
        -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"ro\";" > /dev/null 2>&1
    break
  fi
  sleep 1
done

# ─────────────────────────────────────────────────────────
# Configure Vault database secrets engine + readonly role.
# default_ttl=30s keeps the demo interactive.
# ─────────────────────────────────────────────────────────
vault secrets enable database > /dev/null 2>&1 || true

vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@127.0.0.1:5432/postgres?sslmode=disable" \
  allowed_roles="readonly" \
  username="root" \
  password="rootpassword" > /dev/null

cat > /tmp/readonly.sql <<'EOF'
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT ro TO "{{name}}";
EOF

vault write database/roles/readonly \
  db_name=postgresql \
  creation_statements=@/tmp/readonly.sql \
  default_ttl=30s \
  max_ttl=2m > /dev/null

# ─────────────────────────────────────────────────────────
# AppRole for the Vault Agent path. Policy is read-only on the
# dynamic creds endpoint to mirror least privilege.
# ─────────────────────────────────────────────────────────
vault auth enable approle > /dev/null 2>&1 || true

vault policy write legacy-agent - > /dev/null <<'EOF'
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/legacy-agent \
  token_policies='legacy-agent' \
  token_ttl='30m' \
  token_max_ttl='1h' > /dev/null

vault read -field=role_id auth/approle/role/legacy-agent/role-id > /root/agent-role-id
vault write -force -field=secret_id auth/approle/role/legacy-agent/secret-id > /root/agent-secret-id
chmod 600 /root/agent-role-id /root/agent-secret-id

# ─────────────────────────────────────────────────────────
# Install the "legacy" app as a self-contained bash script.
# It reads creds from env or /etc/legacy-app/config.toml and
# prints `SELECT current_user || ' @ ' || now()` every 10s.
# A bash script (vs a Go binary) keeps the lab independent of
# the Killercoda image's Go toolchain version — the narrative
# only needs an executable with a fixed two-source interface.
# ─────────────────────────────────────────────────────────
mkdir -p "$LAB_DIR" /etc/legacy-app /var/log/legacy-app

cat > /usr/local/bin/legacy-app <<'EOF'
#!/bin/bash
# Simulated legacy application:
#   - Reads DB_USER / DB_PASSWORD env vars first;
#   - Falls back to /etc/legacy-app/config.toml otherwise;
#   - Every 10s, asks Postgres `SELECT current_user || ' @ ' || now()`
#     and prints the result with the credential source tag.
# It has no awareness of Vault — that's the whole point of the demo.

set -u

read_toml() {
  local path=$1 key=$2
  [ -r "$path" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -1
}

echo "[legacy-app] starting"

while true; do
  if [ -n "${DB_USER:-}" ] && [ -n "${DB_PASSWORD:-}" ]; then
    user=$DB_USER; pass=$DB_PASSWORD; src=env
  else
    user=$(read_toml /etc/legacy-app/config.toml username)
    pass=$(read_toml /etc/legacy-app/config.toml password)
    src=file
  fi

  ts=$(date +%H:%M:%S)

  if [ -z "${user:-}" ] || [ -z "${pass:-}" ]; then
    echo "[legacy-app] $ts waiting for credentials (source=$src)"
    sleep 2
    continue
  fi

  short=$user
  if [ ${#short} -gt 24 ]; then
    short="${short:0:24}..."
  fi

  if out=$(PGPASSWORD="$pass" psql -h 127.0.0.1 -p 5432 -U "$user" -d postgres \
            -tA -c "SELECT current_user || ' @ ' || now();" 2>&1); then
    line=$(echo "$out" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e '/^$/d' | head -1)
    echo "[legacy-app] $ts OK    source=$src $line"
  else
    err=$(echo "$out" | tr -d '\r\n')
    echo "[legacy-app] $ts FAIL  source=$src user=$short err=$err"
  fi

  sleep 10
done
EOF
chmod +x /usr/local/bin/legacy-app

# ─────────────────────────────────────────────────────────
# Pre-stage Consul-Template files (config + template):
#   - vault stanza with renew_token, default_lease_duration,
#     lease_renewal_threshold
#   - template uses {{ with secret "database/creds/readonly" }}
# Renewable database leases get auto-renewed by Consul-Template
# at lease half-life by default — no extra toggle needed.
# ─────────────────────────────────────────────────────────
cat > "$LAB_DIR/config.toml.tplt" <<'EOF'
[database]
host = "localhost"
port = 5432
{{ with secret "database/creds/readonly" }}
username = "{{ .Data.username }}"
password = "{{ .Data.password }}"
{{ end }}
EOF

cat > "$LAB_DIR/ct_config.hcl" <<'EOF'
vault {
  address                 = "http://127.0.0.1:8200"
  renew_token             = true   # 自动续期 Vault token（默认为 true，写出来更明显）
  default_lease_duration  = "60s"  # 没有 lease duration 的机密的兜底重查间隔
  lease_renewal_threshold = 0.5    # 不可续期机密才走这里；可续期 lease 不受影响
}
# 另：database/creds/<role> 的 lease 默认可续期，
# Consul-Template 会自动为每份 renewable secret 启动 renewer goroutine，
# 在 lease 半程时调 Vault 的 renew 接口把同一条 lease 续下去，
# 直到逼近 max_ttl 才会重新申请一份全新凭据。
EOF

# ─────────────────────────────────────────────────────────
# Pre-stage Vault Agent process supervisor config.
# ─────────────────────────────────────────────────────────
cat > "$LAB_DIR/vault-agent.hcl" <<'EOF'
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/agent-role-id"
      secret_id_file_path                 = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

vault {
  address = "http://127.0.0.1:8200"
}

env_template "DB_USER" {
  contents             = "{{ with secret \"database/creds/readonly\" }}{{ .Data.username }}{{ end }}"
  error_on_missing_key = true
}

env_template "DB_PASSWORD" {
  contents             = "{{ with secret \"database/creds/readonly\" }}{{ .Data.password }}{{ end }}"
  error_on_missing_key = true
}

exec {
  command                   = ["/usr/local/bin/legacy-app"]
  restart_on_secret_changes = "always"
  restart_stop_signal       = "SIGTERM"
}
EOF

# Initialize config.toml so step 1 can show "before" state.
cat > /etc/legacy-app/config.toml <<'EOF'
[database]
host = "localhost"
port = 5432
# Step 1 will replace these placeholders with a real dynamic credential.
username = ""
password = ""
EOF

cd "$LAB_DIR"
finish_setup
