#!/bin/bash
source /root/setup-common.sh

install_vault
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

vault kv put secret/agent/app \
  username='agent-user' \
  password='initial-password' \
  api_key='initial-api-key' > /dev/null

vault policy write agent-lab - > /dev/null <<'EOF'
path "secret/data/agent/app" {
  capabilities = ["read"]
}
EOF

vault auth enable approle > /dev/null 2>&1 || true
vault write auth/approle/role/agent-lab \
  token_policies='agent-lab' \
  token_ttl='20m' \
  token_max_ttl='1h' > /dev/null

vault read -field=role_id auth/approle/role/agent-lab/role-id > /root/agent-role-id
vault write -force -field=secret_id auth/approle/role/agent-lab/secret-id > /root/agent-secret-id
chmod 600 /root/agent-role-id /root/agent-secret-id

mkdir -p /root/agent-demo

cat > /root/agent-file.ctmpl <<'EOF'
APP_USER={{ with secret "secret/data/agent/app" }}{{ .Data.data.username }}{{ end }}
APP_PASSWORD={{ with secret "secret/data/agent/app" }}{{ .Data.data.password }}{{ end }}
APP_API_KEY={{ with secret "secret/data/agent/app" }}{{ .Data.data.api_key }}{{ end }}
EOF

cat > /root/agent-file.hcl <<'EOF'
pid_file = "/tmp/vault-agent-file.pid"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                = "/root/agent-role-id"
      secret_id_file_path              = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/root/agent-demo/file-agent-token"
    }
  }
}

template_config {
  static_secret_render_interval = "10s"
  exit_on_retry_failure         = true
  max_connections_per_host      = 10
}

template {
  source               = "/root/agent-file.ctmpl"
  destination          = "/root/agent-demo/app.env"
  error_on_missing_key = true
  perms                = "0600"
}
EOF

cat > /root/supervised-app.sh <<'EOF'
#!/bin/bash
echo "started $(date +%H:%M:%S) APP_USER=${APP_USER} APP_PASSWORD=${APP_PASSWORD} APP_API_KEY=${APP_API_KEY}" >> /tmp/supervised-app.log
trap 'echo "stopping $(date +%H:%M:%S)" >> /tmp/supervised-app.log; exit 0' TERM
while true; do
  sleep 2
done
EOF
chmod +x /root/supervised-app.sh

cat > /root/agent-supervisor.hcl <<'EOF'
pid_file = "/tmp/vault-agent-supervisor.pid"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                = "/root/agent-role-id"
      secret_id_file_path              = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "10s"
  exit_on_retry_failure         = true
  max_connections_per_host      = 10
}

env_template "APP_USER" {
  contents             = "{{ with secret \"secret/data/agent/app\" }}{{ .Data.data.username }}{{ end }}"
  error_on_missing_key = true
}

env_template "APP_PASSWORD" {
  contents             = "{{ with secret \"secret/data/agent/app\" }}{{ .Data.data.password }}{{ end }}"
  error_on_missing_key = true
}

env_template "APP_API_KEY" {
  contents             = "{{ with secret \"secret/data/agent/app\" }}{{ .Data.data.api_key }}{{ end }}"
  error_on_missing_key = true
}

exec {
  command                   = ["/root/supervised-app.sh"]
  restart_on_secret_changes = "always"
  restart_stop_signal       = "SIGTERM"
}
EOF

finish_setup