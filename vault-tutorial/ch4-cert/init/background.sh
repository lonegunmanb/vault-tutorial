#!/bin/bash
set +e

source /root/setup-common.sh

apt-get update -qq && apt-get install -y -qq openssl jq curl > /dev/null 2>&1
install_vault

LAB_DIR=/root/cert-lab
mkdir -p "$LAB_DIR"

cat > "$LAB_DIR/server.cnf" <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[ req_distinguished_name ]
CN = localhost
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

cat > "$LAB_DIR/web-client.cnf" <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[ req_distinguished_name ]
CN = web-01.example.org
OU = platform
[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = web-01.example.org
EOF

cat > "$LAB_DIR/db-client.cnf" <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[ req_distinguished_name ]
CN = db-01.example.org
OU = database
[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = db-01.example.org
EOF

generate_cert_material() {
  openssl genrsa -out "$LAB_DIR/server-ca.key" 2048
  openssl req -x509 -new -nodes -key "$LAB_DIR/server-ca.key" -sha256 -days 365 \
    -subj "/CN=Vault Lab Server CA" -out "$LAB_DIR/server-ca.crt"
  openssl genrsa -out "$LAB_DIR/vault-server.key" 2048
  openssl req -new -key "$LAB_DIR/vault-server.key" -out "$LAB_DIR/vault-server.csr" -config "$LAB_DIR/server.cnf"
  openssl x509 -req -in "$LAB_DIR/vault-server.csr" \
    -CA "$LAB_DIR/server-ca.crt" -CAkey "$LAB_DIR/server-ca.key" -CAcreateserial \
    -out "$LAB_DIR/vault-server.crt" -days 365 -sha256 -extensions v3_req -extfile "$LAB_DIR/server.cnf"

  openssl genrsa -out "$LAB_DIR/client-ca.key" 2048
  openssl req -x509 -new -nodes -key "$LAB_DIR/client-ca.key" -sha256 -days 365 \
    -subj "/CN=Vault Lab Client CA" -out "$LAB_DIR/client-ca.crt"

  openssl genrsa -out "$LAB_DIR/web-client.key" 2048
  openssl req -new -key "$LAB_DIR/web-client.key" -out "$LAB_DIR/web-client.csr" -config "$LAB_DIR/web-client.cnf"
  openssl x509 -req -in "$LAB_DIR/web-client.csr" \
    -CA "$LAB_DIR/client-ca.crt" -CAkey "$LAB_DIR/client-ca.key" -CAcreateserial \
    -out "$LAB_DIR/web-client.crt" -days 90 -sha256 -extensions v3_req -extfile "$LAB_DIR/web-client.cnf"

  openssl genrsa -out "$LAB_DIR/db-client.key" 2048
  openssl req -new -key "$LAB_DIR/db-client.key" -out "$LAB_DIR/db-client.csr" -config "$LAB_DIR/db-client.cnf"
  openssl x509 -req -in "$LAB_DIR/db-client.csr" \
    -CA "$LAB_DIR/client-ca.crt" -CAkey "$LAB_DIR/client-ca.key" -CAcreateserial \
    -out "$LAB_DIR/db-client.crt" -days 90 -sha256 -extensions v3_req -extfile "$LAB_DIR/db-client.cnf"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$LAB_DIR/rogue-client.key" -out "$LAB_DIR/rogue-client.crt" \
    -days 90 -sha256 -subj "/CN=web-rogue.example.org/OU=platform" \
    -addext "extendedKeyUsage=clientAuth" \
    -addext "subjectAltName=DNS:web-rogue.example.org" > /dev/null 2>&1
}

generate_cert_material

cat > "$LAB_DIR/vault-tls.hcl" <<EOF
storage "inmem" {}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = false
  tls_disable_client_certs = false
  tls_cert_file = "$LAB_DIR/vault-server.crt"
  tls_key_file = "$LAB_DIR/vault-server.key"
}

disable_mlock = true
api_addr = "https://127.0.0.1:8200"
ui = true
EOF

vault server -config="$LAB_DIR/vault-tls.hcl" > /var/log/vault-tls.log 2>&1 &

echo "Waiting for TLS Vault server to listen..."
for i in $(seq 1 30); do
  if curl --cacert "$LAB_DIR/server-ca.crt" -s https://127.0.0.1:8200/v1/sys/health > /dev/null 2>&1; then
    echo "TLS Vault listener is reachable."
    break
  fi
  sleep 1
done

export VAULT_ADDR='https://127.0.0.1:8200'
export VAULT_CACERT="$LAB_DIR/server-ca.crt"

vault operator init -key-shares=1 -key-threshold=1 -format=json > "$LAB_DIR/vault-init.json"
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "$LAB_DIR/vault-init.json")
ROOT_TOKEN=$(jq -r '.root_token' "$LAB_DIR/vault-init.json")
vault operator unseal "$UNSEAL_KEY" > /dev/null

cat > /etc/profile.d/vault.sh <<EOF
export VAULT_ADDR='https://127.0.0.1:8200'
export VAULT_CACERT='$LAB_DIR/server-ca.crt'
export VAULT_TOKEN='$ROOT_TOKEN'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR='https://127.0.0.1:8200'" /root/.bashrc 2>/dev/null || cat /etc/profile.d/vault.sh >> /root/.bashrc

export VAULT_TOKEN="$ROOT_TOKEN"
vault status > /dev/null 2>&1 || cat /var/log/vault-tls.log
vault secrets enable -path=secret kv-v2 > /dev/null 2>&1 || true

cd /root
finish_setup