#!/bin/sh
set -e

if [ -z "${VAULT_ADDR_FROM_CONTAINER:-}" ]; then
  echo "ERROR: VAULT_ADDR_FROM_CONTAINER must be set (e.g. http://172.17.0.1:8200)" >&2
  exit 1
fi

if [ -z "${SSH_MOUNT_POINT:-}" ]; then
  echo "ERROR: SSH_MOUNT_POINT must be set (e.g. ssh or ssh-otp)" >&2
  exit 1
fi

mkdir -p /etc/vault-ssh-helper.d
cat > /etc/vault-ssh-helper.d/config.hcl <<EOF
vault_addr        = "${VAULT_ADDR_FROM_CONTAINER}"
ssh_mount_point   = "${SSH_MOUNT_POINT}"
tls_skip_verify   = true
allowed_roles     = "*"
EOF

echo "--- vault-ssh-helper -verify-only ---"
/usr/local/bin/vault-ssh-helper -dev -verify-only \
  -config=/etc/vault-ssh-helper.d/config.hcl || true

echo "Starting sshd on port 22..."
exec /usr/sbin/sshd -D -e
