#!/bin/bash
set -Eeuo pipefail

LOG=/var/log/ldap-mfa-init.log
exec > >(tee -a "$LOG") 2>&1
export PS4='+ [\D{%H:%M:%S}] '
set -x

stage() { echo "===== [$(date +%H:%M:%S)] $* ====="; }
mark_failed() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: background.sh failed with exit code $rc"
    touch /tmp/.setup-failed
  fi
}
trap mark_failed EXIT

stage "background.sh start"

if [ ! -f /root/setup-common.sh ]; then
  echo "FATAL: /root/setup-common.sh missing - assets were not copied. Aborting."
  exit 1
fi
source /root/setup-common.sh

export DEBIAN_FRONTEND=noninteractive

stage "apt install ldap-utils + oathtool + jq + curl"
apt-get update -qq
apt-get install -y -qq ldap-utils oathtool jq curl unzip > /dev/null 2>&1

if ! command -v docker > /dev/null 2>&1; then
  apt-get install -y -qq docker.io > /dev/null 2>&1
fi

stage "install Vault + Go 1.22 + pull OpenLDAP"
install_vault > /var/log/install-vault.log 2>&1 &
INSTALL_VAULT_PID=$!

install_go() {
  set -e
  if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version | grep -q 'go1.22'; then
    echo "go 1.22 already installed"
    return 0
  fi
  curl --connect-timeout 10 --max-time 240 -fsSL \
    https://go.dev/dl/go1.22.10.linux-amd64.tar.gz -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
}
install_go > /var/log/install-go.log 2>&1 &
INSTALL_GO_PID=$!

docker pull osixia/openldap:1.5.0 > /dev/null 2>&1 &
PULL_LDAP_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_GO_PID"
wait "$PULL_LDAP_PID"

export PATH=/usr/local/go/bin:$PATH
cat > /etc/profile.d/go.sh <<'EOF'
export PATH=/usr/local/go/bin:$PATH
EOF
chmod +x /etc/profile.d/go.sh

stage "start OpenLDAP"
docker rm -f vault-openldap > /dev/null 2>&1 || true
docker run -d \
  --name vault-openldap \
  -p 389:389 \
  -e LDAP_ORGANISATION="learn" \
  -e LDAP_DOMAIN="learn.example" \
  -e LDAP_ADMIN_PASSWORD="2LearnVault" \
  -e LDAP_CONFIG_PASSWORD="2LearnVault" \
  --rm \
  osixia/openldap:1.5.0 > /dev/null

LDAP_READY=0
for i in $(seq 1 60); do
  if ldapsearch -x -H ldap://127.0.0.1:389 \
      -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
      -b "dc=learn,dc=example" -s base "(objectClass=*)" > /dev/null 2>&1; then
    echo "OpenLDAP ready"
    LDAP_READY=1
    break
  fi
  sleep 1
done
if [ "$LDAP_READY" != "1" ]; then
  echo "FATAL: OpenLDAP did not become ready"
  docker logs vault-openldap || true
  exit 1
fi

ldapadd -c -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=learn,dc=example" -w 2LearnVault <<'EOF' > /tmp/ldapadd.log 2>&1
dn: ou=users,dc=learn,dc=example
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=learn,dc=example
objectClass: organizationalUnit
ou: groups

dn: cn=alice,ou=users,dc=learn,dc=example
objectClass: person
cn: alice
sn: Liddell
userPassword: LdapPass!2026
EOF

stage "start_vault_dev + enable audit"
start_vault_dev
touch /var/log/vault-audit.log
chmod 666 /var/log/vault-audit.log
vault audit enable file file_path=/var/log/vault-audit.log > /dev/null 2>&1 || true

stage "enable + configure auth/ldap"
vault auth enable ldap > /dev/null 2>&1 || true
vault write auth/ldap/config \
  url="ldap://127.0.0.1:389" \
  userdn="ou=users,dc=learn,dc=example" \
  groupdn="ou=groups,dc=learn,dc=example" \
  userattr="cn" \
  binddn="cn=admin,dc=learn,dc=example" \
  bindpass="2LearnVault" \
  insecure_tls=true > /dev/null

LDAP_ACC=$(vault auth list -format=json | jq -r '.["ldap/"].accessor')
echo "LDAP accessor: $LDAP_ACC"
echo "$LDAP_ACC" > /root/ldap-accessor

stage "enable totp secrets engine"
vault secrets enable totp > /dev/null 2>&1 || true
echo "alice" > /root/totp-key-name

cat > /etc/profile.d/totp.sh <<'EOF'
export TOTP_KEY_NAME='alice'
EOF
chmod +x /etc/profile.d/totp.sh
grep -q "TOTP_KEY_NAME=" /root/.bashrc 2>/dev/null || \
  echo "export TOTP_KEY_NAME='alice'" >> /root/.bashrc

stage "create alice-totp-login policy"
vault policy write alice-totp-login - <<'EOF' > /dev/null
path "totp/code/alice" {
  capabilities = ["update"]
}
EOF

stage "pre-create alice entity + alias + policy (no TOTP key yet)"
ALICE_EID=$(vault write -field=id identity/entity name=alice policies=default,alice-totp-login)
vault write identity/entity-alias \
  name=alice \
  canonical_id="$ALICE_EID" \
  mount_accessor="$LDAP_ACC" > /dev/null
echo "$ALICE_EID" > /root/alice-entity-id

cat > /usr/local/bin/enroll-alice.sh <<'EOF'
#!/bin/bash
set -e

RESP=$(vault write -format=json \
  totp/keys/alice \
  generate=true \
  exported=true \
  issuer="MyWebsite" \
  account_name="alice" \
  period=30 \
  algorithm=SHA1 \
  digits=6)
URL=$(echo "$RESP" | jq -r '.data.url')
SECRET=$(echo "$URL" | sed -n 's/.*[?&]secret=\([^&]*\).*/\1/p')
if [ -z "$SECRET" ]; then
  echo "ERROR: failed to parse TOTP secret from $URL"
  exit 1
fi
echo "$SECRET" > /root/alice-totp-secret
chmod 600 /root/alice-totp-secret
echo "------------------------------------------------------------"
echo "  Enrollment 完成。"
echo "  otpauth URL  : $URL"
echo "  TOTP secret  : $SECRET"
echo "  已写入       : /root/alice-totp-secret"
echo ""
echo "  现在可以用下面这条命令算出当前 6 位验证码（每 30 秒一变）："
echo "    oathtool --totp -b \"\$(cat /root/alice-totp-secret)\""
echo "------------------------------------------------------------"
EOF
chmod +x /usr/local/bin/enroll-alice.sh

stage "build + start web app"
mkdir -p /root/web-app
cd /root/web-app
GOPROXY=off CGO_ENABLED=0 go build -o app . 2>&1 | tee /var/log/go-build.log
if [ ! -x /root/web-app/app ]; then
  echo "FATAL: app build failed"
  cat /var/log/go-build.log
  exit 1
fi

cat > /usr/local/bin/start-web-app.sh <<'EOF'
#!/bin/bash
set -e
pkill -f /root/web-app/app 2>/dev/null || true
sleep 1
export VAULT_ADDR='http://127.0.0.1:8200'
TOTP_KEY_NAME=$(cat /root/totp-key-name)
if [ -z "$TOTP_KEY_NAME" ]; then
  echo "FATAL: /root/totp-key-name is empty"
  exit 1
fi
export TOTP_KEY_NAME
export APP_ADDR=':8080'
nohup /root/web-app/app > /var/log/web-app.log 2>&1 &
sleep 1
pid=$(pgrep -f /root/web-app/app || true)
echo "web-app pid=$pid, logs: /var/log/web-app.log"
EOF
chmod +x /usr/local/bin/start-web-app.sh
/usr/local/bin/start-web-app.sh

cd /root
stage "finish_setup"
finish_setup
stage "background.sh DONE"