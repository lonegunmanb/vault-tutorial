#!/bin/bash
set +e

LOG=/var/log/ldap-rotation-init.log
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

stage "install vault (background) + apt install ldap-utils + jq"
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq
apt-get install -y -qq ldap-utils jq curl > /dev/null 2>&1

# 启动 OpenLDAP 容器（osixia 1.5.0；与 ch3-ldap 用同一镜像，但用 learn.example
# 域、与官方 openldap tutorial 对齐，便于学员把两边对照阅读）
start_openldap() {
  if ! command -v docker > /dev/null 2>&1; then
    echo "WARNING: docker not available; cannot start openldap"
    return 1
  fi
  docker rm -f vault-openldap > /dev/null 2>&1 || true
  docker run -d \
    --name vault-openldap \
    -p 389:389 \
    -e LDAP_ORGANISATION="learn" \
    -e LDAP_DOMAIN="learn.example" \
    -e LDAP_ADMIN_PASSWORD="2LearnVault" \
    --rm \
    osixia/openldap:1.5.0 > /dev/null

  echo "Waiting for OpenLDAP to be ready..."
  for i in $(seq 1 60); do
    if ldapsearch -x -H ldap://127.0.0.1:389 \
        -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
        -b "dc=learn,dc=example" -s base "(objectClass=*)" > /dev/null 2>&1; then
      echo "OpenLDAP is ready."
      return 0
    fi
    sleep 1
  done
  echo "WARNING: OpenLDAP did not become healthy within 60 seconds"
  docker logs vault-openldap | tail -50
  return 1
}

stage "start_openldap"
start_openldap

# 写入与官方 openldap tutorial 完全一致的种子数据：alice 位于 ou=users 下，
# 初始口令 1LearnedVault；同时建一个 cn=dev 组方便学员后续探索。
#
# 还要额外补一个 cn=admin,dc=learn,dc=example 的真实条目：osixia/openldap 容器
# 默认只把 admin 设为 slapd 的 rootdn（仅写在 cn=config 里，DIT 树里并没有这条
# 条目），而 Vault 的 ldap/rotate-root 实现会先去 DIT 里 search 这个 binddn，
# 找不到就返回 LDAP Result Code 32 "No Such Object"，导致 rotate-root 失败。
# 这里补建该条目并把 userPassword 同步设为 2LearnVault，让 step2 的 rotate-root
# 既能查到目标条目、又能用同一份口令成功 bind。
seed_ldap_entries() {
  ldapadd -c -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=learn,dc=example" -w 2LearnVault <<'EOF'
dn: ou=groups,dc=learn,dc=example
objectClass: organizationalUnit
objectClass: top
ou: groups

dn: ou=users,dc=learn,dc=example
objectClass: organizationalUnit
objectClass: top
ou: users

dn: cn=dev,ou=groups,dc=learn,dc=example
objectClass: groupOfNames
objectClass: top
cn: dev
member: cn=alice,ou=users,dc=learn,dc=example

dn: cn=alice,ou=users,dc=learn,dc=example
objectClass: person
objectClass: top
cn: alice
sn: Liddell
userPassword: 1LearnedVault

dn: cn=admin,dc=learn,dc=example
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
description: LDAP administrator entry (created so Vault rotate-root can find it)
userPassword: 2LearnVault
EOF
}

count_alice() {
  ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
    -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>/dev/null \
    | grep -c '^cn:'
}

for attempt in 1 2 3 4 5; do
  seed_ldap_entries > /tmp/ldapadd.log 2>&1 || true
  if [ "$(count_alice)" -ge 1 ]; then
    echo "Seeded alice on attempt $attempt."
    break
  fi
  echo "Seed attempt $attempt did not see alice; retrying in 2s..."
  sleep 2
done

if [ "$(count_alice)" -lt 1 ]; then
  echo "ERROR: failed to seed alice. ldapadd log:"
  cat /tmp/ldapadd.log
fi

stage "wait for vault install to finish"
wait "$INSTALL_VAULT_PID"

stage "start_vault_dev"
start_vault_dev

cd /root
finish_setup
stage "background.sh DONE"
