#!/bin/bash
# setup-otp-target.sh — runs INSIDE the OTP target container.
#
# Installs vault-ssh-helper, configures PAM and sshd to delegate the
# `auth` step to vault-ssh-helper, so each SSH login validates the
# password as a one-time token issued by Vault.
#
# Expects:
#   $VAULT_ADDR_FROM_CONTAINER — URL the container can use to reach
#                                 Vault on the docker host
#                                 (e.g. http://172.17.0.1:8200)
#   $SSH_MOUNT_POINT           — Vault SSH engine mount path (e.g. ssh)
#
# Idempotent: re-running just overwrites configs.

set -e

VAULT_SSH_HELPER_VERSION="${VAULT_SSH_HELPER_VERSION:-0.2.1}"

# 1) Install helper binary
apt-get update -qq
apt-get install -y -qq openssh-server unzip curl ca-certificates > /dev/null

if [ ! -x /usr/local/bin/vault-ssh-helper ]; then
  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://releases.hashicorp.com/vault-ssh-helper/${VAULT_SSH_HELPER_VERSION}/vault-ssh-helper_${VAULT_SSH_HELPER_VERSION}_linux_amd64.zip" \
    -o /tmp/vsh.zip
  unzip -o -q /tmp/vsh.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/vault-ssh-helper
  rm -f /tmp/vsh.zip
fi

# 2) Helper config — points at Vault on the docker host
mkdir -p /etc/vault-ssh-helper.d
cat > /etc/vault-ssh-helper.d/config.hcl <<EOF
vault_addr        = "${VAULT_ADDR_FROM_CONTAINER}"
ssh_mount_point   = "${SSH_MOUNT_POINT}"
tls_skip_verify   = true
allowed_roles     = "*"
EOF

# 3) PAM: hand "auth" to vault-ssh-helper
#    requisite + expose_authtok 让 helper 收到 sshd 收到的密码
cat > /etc/pam.d/sshd <<'EOF'
auth requisite pam_exec.so quiet expose_authtok log=/tmp/vault-ssh.log /usr/local/bin/vault-ssh-helper -dev -config=/etc/vault-ssh-helper.d/config.hcl
auth optional  pam_unix.so not_set_pass use_first_pass nodelay
account required pam_unix.so
session required pam_unix.so
EOF

# 4) sshd_config: 必须开 KbdInteractive + UsePAM，关掉公钥/密码方式
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

# 5) Make sure the login user exists with no shell password (PAM will reject pam_unix in auth chain)
id ubuntu > /dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
passwd -d ubuntu > /dev/null 2>&1 || true

# 6) Generate host keys if missing
ssh-keygen -A > /dev/null 2>&1

# 7) Self-check
echo "--- vault-ssh-helper -verify-only ---"
/usr/local/bin/vault-ssh-helper -dev -verify-only \
  -config=/etc/vault-ssh-helper.d/config.hcl || true

# 8) Start sshd in foreground (script is meant to be exec'd then sshd run separately)
echo "OTP target ready. Start sshd with: /usr/sbin/sshd -D"
