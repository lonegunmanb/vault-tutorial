#!/bin/bash
set -Eeuo pipefail

VAULT_SSH_HELPER_VERSION="${VAULT_SSH_HELPER_VERSION:-0.2.1}"
OTP_LOGIN_USER="${OTP_LOGIN_USER:-vaultlab}"

install_target_packages() {
  for attempt in 1 2 3; do
    echo "Installing target SSH packages, attempt $attempt/3..."
    if timeout 120s env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      && timeout 180s env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        --no-install-recommends openssh-server unzip curl ca-certificates > /dev/null; then
      return 0
    fi
    echo "Target package installation failed on attempt $attempt; retrying in 5 seconds..."
    sleep 5
  done
  echo "ERROR: failed to install target SSH packages."
  return 1
}

install_target_packages

if [ ! -x /usr/local/bin/vault-ssh-helper ]; then
  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://releases.hashicorp.com/vault-ssh-helper/${VAULT_SSH_HELPER_VERSION}/vault-ssh-helper_${VAULT_SSH_HELPER_VERSION}_linux_amd64.zip" \
    -o /tmp/vault-ssh-helper.zip
  unzip -o -q /tmp/vault-ssh-helper.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/vault-ssh-helper
  rm -f /tmp/vault-ssh-helper.zip
fi

mkdir -p /etc/vault-ssh-helper.d
cat > /etc/vault-ssh-helper.d/config.hcl <<EOF
vault_addr        = "${VAULT_ADDR_FROM_CONTAINER}"
ssh_mount_point   = "${SSH_MOUNT_POINT}"
tls_skip_verify   = true
allowed_roles     = "*"
EOF

cat > /etc/pam.d/sshd <<'EOF'
auth requisite pam_exec.so quiet expose_authtok log=/tmp/vault-ssh.log /usr/local/bin/vault-ssh-helper -dev -config=/etc/vault-ssh-helper.d/config.hcl
auth optional  pam_unix.so not_set_pass use_first_pass nodelay
account required pam_unix.so
session required pam_unix.so
EOF

mkdir -p /var/run/sshd
cat > /etc/ssh/sshd_config <<'EOF'
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication no
ChallengeResponseAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

id "$OTP_LOGIN_USER" > /dev/null 2>&1 || useradd -m -s /bin/bash "$OTP_LOGIN_USER"
passwd -d "$OTP_LOGIN_USER" > /dev/null 2>&1 || true

ssh-keygen -A > /dev/null 2>&1

echo "--- vault-ssh-helper -verify-only ---"
/usr/local/bin/vault-ssh-helper -dev -verify-only \
  -config=/etc/vault-ssh-helper.d/config.hcl

echo "OTP target is ready for user ${OTP_LOGIN_USER}."