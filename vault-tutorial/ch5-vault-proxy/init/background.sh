#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1
fi

start_vault_dev

vault kv put secret/proxy/app username="proxy-demo" password="training-password" > /dev/null

vault auth enable approle > /dev/null

cat > /root/proxy-app-read.hcl <<'EOF'
path "secret/data/proxy/app" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

vault policy write proxy-app-read /root/proxy-app-read.hcl > /dev/null

vault write auth/approle/role/proxy-app \
  token_policies="proxy-app-read" \
  token_ttl="30m" \
  token_max_ttl="2h" \
  token_num_uses=0 > /dev/null

vault read -field=role_id auth/approle/role/proxy-app/role-id > /root/proxy-role-id
vault write -field=secret_id -force auth/approle/role/proxy-app/secret-id > /root/proxy-secret-id
chmod 600 /root/proxy-role-id /root/proxy-secret-id

cat > /root/proxy-config.hcl <<'EOF'
pid_file = "/tmp/vault-proxy.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
  retry {
    num_retries = 3
  }
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/root/proxy-role-id"
      secret_id_file_path                 = "/root/proxy-secret-id"
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
