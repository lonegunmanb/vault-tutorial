#!/bin/bash
set +e

LOG=/var/log/ldap-mfa-init.log
exec > >(tee -a "$LOG") 2>&1
export PS4='+ [\D{%H:%M:%S}] '
set -x

stage() { echo "===== [$(date +%H:%M:%S)] $* ====="; }
stage "background.sh start"

if [ ! -f /root/setup-common.sh ]; then
  echo "FATAL: /root/setup-common.sh missing — assets were not copied. Aborting."
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

# ──────────────────────────────────────────────────────────
# 并行：装 Vault、装 Go 1.22、拉 OpenLDAP 镜像
# ──────────────────────────────────────────────────────────
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
wait "$PULL_LDAP_PID" 2>/dev/null

export PATH=/usr/local/go/bin:$PATH
cat > /etc/profile.d/go.sh <<'EOF'
export PATH=/usr/local/go/bin:$PATH
EOF
chmod +x /etc/profile.d/go.sh

# ──────────────────────────────────────────────────────────
# 启动 OpenLDAP，预置 ou=users / ou=groups + alice 用户
# ──────────────────────────────────────────────────────────
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

for i in $(seq 1 60); do
  if ldapsearch -x -H ldap://127.0.0.1:389 \
      -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
      -b "dc=learn,dc=example" -s base "(objectClass=*)" > /dev/null 2>&1; then
    echo "OpenLDAP ready"
    break
  fi
  sleep 1
done

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

# ──────────────────────────────────────────────────────────
# 启动 Vault dev + 开 audit
# ──────────────────────────────────────────────────────────
stage "start_vault_dev + enable audit"
start_vault_dev
touch /var/log/vault-audit.log
chmod 666 /var/log/vault-audit.log
vault audit enable file file_path=/var/log/vault-audit.log > /dev/null

# ──────────────────────────────────────────────────────────
# 四块积木之 1：auth/ldap
# ──────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────
# 四块积木之 2：TOTP MFA method
# ──────────────────────────────────────────────────────────
stage "create totp mfa method my-totp"
vault write sys/mfa/method/totp/my-totp \
  issuer="MyWebsite" \
  period=30 \
  algorithm=SHA1 \
  digits=6 > /dev/null

TOTP_ID=$(vault read -field=method_id sys/mfa/method/totp/my-totp)
echo "TOTP method_id: $TOTP_ID"
echo "$TOTP_ID" > /root/totp-method-id

# 把 TOTP_METHOD_ID 写进所有 shell 的环境
cat > /etc/profile.d/totp.sh <<EOF
export TOTP_METHOD_ID='$TOTP_ID'
EOF
chmod +x /etc/profile.d/totp.sh
grep -q "TOTP_METHOD_ID=" /root/.bashrc 2>/dev/null || \
  echo "export TOTP_METHOD_ID='$TOTP_ID'" >> /root/.bashrc

# ──────────────────────────────────────────────────────────
# 四块积木之 3：Login Enforcement
# ──────────────────────────────────────────────────────────
stage "create login-enforcement ldap-mfa-enforce"
vault write sys/mfa/login-enforcement/ldap-mfa-enforce \
  mfa_method_ids="$TOTP_ID" \
  auth_method_types="ldap" \
  auth_method_accessors="$LDAP_ACC" > /dev/null

# ──────────────────────────────────────────────────────────
# 破"鸡生蛋"：预先为 alice 创建 Identity Entity + entity-alias，
# 但不生成 TOTP 密钥 —— step 2 让学员亲手跑 enrollment 把它补上。
# ──────────────────────────────────────────────────────────
stage "pre-create alice entity + alias (no TOTP yet)"
ALICE_EID=$(vault write -field=id identity/entity name=alice policies=default)
vault write identity/entity-alias \
  name=alice \
  canonical_id="$ALICE_EID" \
  mount_accessor="$LDAP_ACC" > /dev/null
echo "$ALICE_EID" > /root/alice-entity-id

# ──────────────────────────────────────────────────────────
# 准备 enrollment 脚本：step 2 让学员单击运行
# ──────────────────────────────────────────────────────────
cat > /usr/local/bin/enroll-alice.sh <<'EOF'
#!/bin/bash
# 给 alice 生成一份 TOTP 密钥并把它注入本地 oathtool。
# 这一步在真实生产里是一个独立的 enrollment service：用户拿一次性邀请链接
# 打开后，后端用 admin token 跑等价的命令并把二维码 PNG 推给用户扫码。
set -e
ENTITY_ID=$(cat /root/alice-entity-id)
RESP=$(vault write -format=json \
  sys/mfa/method/totp/my-totp/admin-generate \
  entity_id="$ENTITY_ID")
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

# ──────────────────────────────────────────────────────────
# 编译 Go 网站并以 nohup 起到 :8080
# 注意：站点依赖 TOTP_METHOD_ID 环境变量，所以传给子进程时显式 export。
# ──────────────────────────────────────────────────────────
stage "build + start web app"
mkdir -p /root/web-app
cd /root/web-app
ls -la
GOPROXY=off CGO_ENABLED=0 go build -o app . 2>&1 | tee /var/log/go-build.log
if [ ! -x /root/web-app/app ]; then
  echo "FATAL: app build failed"
  cat /var/log/go-build.log
  exit 1
fi

# 用一个独立的启动脚本封装，方便学员在 step 中重启
cat > /usr/local/bin/start-web-app.sh <<'EOF'
#!/bin/bash
pkill -f /root/web-app/app 2>/dev/null
sleep 1
export VAULT_ADDR='http://127.0.0.1:8200'
export TOTP_METHOD_ID=$(cat /root/totp-method-id)
export APP_ADDR=':8080'
nohup /root/web-app/app > /var/log/web-app.log 2>&1 &
sleep 1
echo "web-app pid=$(pgrep -f /root/web-app/app), logs: /var/log/web-app.log"
EOF
chmod +x /usr/local/bin/start-web-app.sh
/usr/local/bin/start-web-app.sh

cd /root
stage "finish_setup"
finish_setup
stage "background.sh DONE"
