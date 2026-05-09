#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1
fi

start_vault_dev

# Pre-stage the unified KV secret all three methods will fetch.
vault kv put secret/seven/app username="seven-demo" password="ch7-overview-password" > /dev/null

vault auth enable approle > /dev/null

cat > /root/seven-app-read.hcl <<'EOF'
path "secret/data/seven/app" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

vault policy write seven-app-read /root/seven-app-read.hcl > /dev/null

vault write auth/approle/role/seven-app \
  token_policies="seven-app-read" \
  token_ttl="30m" \
  token_max_ttl="2h" \
  token_num_uses=0 > /dev/null

vault read -field=role_id auth/approle/role/seven-app/role-id > /root/seven-role-id
vault write -field=secret_id -force auth/approle/role/seven-app/secret-id > /root/seven-secret-id
chmod 600 /root/seven-role-id /root/seven-secret-id

# Vault Agent configuration: AppRole auto-auth + template rendering to file.
cat > /root/agent-config.hcl <<'EOF'
pid_file = "/tmp/vault-agent.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/root/seven-role-id"
      secret_id_file_path                 = "/root/seven-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      path = "/root/agent-token"
    }
  }
}

template {
  destination = "/root/agent-secret.txt"
  contents = <<EOT
{{ with secret "secret/data/seven/app" -}}
username={{ .Data.data.username }}
password={{ .Data.data.password }}
{{- end }}
EOT
}
EOF

# Vault Proxy configuration: AppRole auto-auth + force API proxy on a local listener.
cat > /root/proxy-config.hcl <<'EOF'
pid_file = "/tmp/vault-proxy.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/root/seven-role-id"
      secret_id_file_path                 = "/root/seven-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      path = "/root/proxy-token"
    }
  }
}

cache {}

api_proxy {
  use_auto_auth_token = "force"
}

listener "tcp" {
  address                = "127.0.0.1:8100"
  tls_disable            = true
  require_request_header = true
}
EOF

cd /root
finish_setup
