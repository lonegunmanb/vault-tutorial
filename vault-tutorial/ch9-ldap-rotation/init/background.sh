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
    -e LDAP_CONFIG_PASSWORD="2LearnVault" \
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
# 另外补一个专门给 Vault 用的服务账号 cn=vault,ou=services：
#   - 初始口令 2VaultBootstrap，只是为了让 step2 里首次 vault write ldap/config
#     能 bind 上 LDAP；Vault 被要求的第二动作就是 rotate-root，之后这个初始值
#     会被一段随机串覆盖、仅存于 Vault 内部。
#   - 这个账号不是 rootdn，所以 slapd 给它的认证走 DIT 里的 userPassword，
#     rotate-root 改什么就生效什么——这才是生产里的正确姿势。
#   - cn=admin 这条 rootdn 则保留不动：它是运维侧的 break-glass，永远不交给 Vault。
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

dn: ou=services,dc=learn,dc=example
objectClass: organizationalUnit
objectClass: top
ou: services

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

dn: cn=vault,ou=services,dc=learn,dc=example
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: vault
description: Dedicated service account for HashiCorp Vault ldap secrets engine
userPassword: 2VaultBootstrap
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

# 关键收尾：给 mdb 后端加一条 ACL，让 cn=vault 服务账号能写 userPassword。
# 背景：OpenLDAP 默认只允许 by self write（所以 cn=vault 能改自己的 userPassword、
# 也就是能 rotate-root），但不能改别人的 userPassword。要让它 step3 能代管 alice
# 的口令，必须显式授权。我们重写整个 olcAccess：
#   - {0}：attrs=userPassword：self 写、cn=vault 写、匿名走 auth，其他人看不到。
#   - {1}：其他属性：self 写、任何已认证身份可读。
# rootdn （cn=admin）不受 olcAccess 限制，运维侧的 break-glass 能力不受影响。
add_vault_acl() {
  ldapmodify -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,cn=config" -w 2LearnVault <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by self write by dn.exact="cn=vault,ou=services,dc=learn,dc=example" write by anonymous auth by * none
olcAccess: {1}to * by self write by users read by * none
EOF
}

for attempt in 1 2 3 4 5; do
  if add_vault_acl > /tmp/vaultacl.log 2>&1; then
    echo "Added vault ACL on attempt $attempt."
    break
  fi
  echo "add_vault_acl attempt $attempt failed; retrying in 2s..."
  cat /tmp/vaultacl.log
  sleep 2
done

stage "wait for vault install to finish"
wait "$INSTALL_VAULT_PID"

stage "start_vault_dev"
start_vault_dev

cd /root
finish_setup
stage "background.sh DONE"
