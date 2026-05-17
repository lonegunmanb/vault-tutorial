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
# Build the "legacy" Go binary. It reads creds from env or
# /etc/legacy-app/config.toml and prints `SELECT current_user`
# every 10 seconds. Uses only stdlib + os/exec (psql),
# so it builds with the pre-installed Go 1.18 on Killercoda.
# ─────────────────────────────────────────────────────────
mkdir -p "$LAB_DIR" /etc/legacy-app /var/log/legacy-app

cat > "$LAB_DIR/legacy-app.go" <<'EOF'
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

func readToml(path string) (user, pass string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if i := strings.Index(line, "="); i > 0 {
			k := strings.TrimSpace(line[:i])
			v := strings.Trim(strings.TrimSpace(line[i+1:]), "\"")
			switch k {
			case "username":
				user = v
			case "password":
				pass = v
			}
		}
	}
	return
}

func loadCreds() (string, string, string) {
	if u, p := os.Getenv("DB_USER"), os.Getenv("DB_PASSWORD"); u != "" && p != "" {
		return u, p, "env"
	}
	u, p := readToml("/etc/legacy-app/config.toml")
	return u, p, "file"
}

func query(user, pass string) (string, error) {
	cmd := exec.Command("psql",
		"-h", "127.0.0.1", "-p", "5432",
		"-U", user, "-d", "postgres",
		"-tA", "-c", "SELECT current_user || ' @ ' || now();")
	cmd.Env = append(os.Environ(), "PGPASSWORD="+pass)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func main() {
	fmt.Fprintln(os.Stdout, "[legacy-app] starting")
	for {
		user, pass, src := loadCreds()
		ts := time.Now().Format("15:04:05")
		if user == "" || pass == "" {
			fmt.Fprintf(os.Stdout, "[legacy-app] %s waiting for credentials (source=%s)\n", ts, src)
			time.Sleep(2 * time.Second)
			continue
		}
		short := user
		if len(short) > 24 {
			short = short[:24] + "..."
		}
		out, err := query(user, pass)
		if err != nil {
			fmt.Fprintf(os.Stdout, "[legacy-app] %s FAIL  source=%s user=%s err=%v %s\n", ts, src, short, err, out)
		} else {
			fmt.Fprintf(os.Stdout, "[legacy-app] %s OK    source=%s %s\n", ts, src, out)
		}
		time.Sleep(10 * time.Second)
	}
}
EOF

# Build with the preinstalled go (1.18 on the killercoda ubuntu image).
# No external imports, so no module download required.
(
  cd "$LAB_DIR"
  GOFLAGS="-mod=mod" go build -o /usr/local/bin/legacy-app legacy-app.go > /tmp/legacy-build.log 2>&1
) || {
  echo "WARNING: legacy-app build failed; tailing log:"
  cat /tmp/legacy-build.log
}
chmod +x /usr/local/bin/legacy-app 2>/dev/null

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
