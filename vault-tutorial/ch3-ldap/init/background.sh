#!/bin/bash
set +e

source /root/setup-common.sh

# ─────────────────────────────────────────────────────────
# 并行：装 vault + 装工具 + 拉 openldap 镜像
# ─────────────────────────────────────────────────────────
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq ldap-utils jq > /dev/null 2>&1

# 启动 OpenLDAP 容器
start_openldap() {
  if ! command -v docker > /dev/null 2>&1; then
    echo "WARNING: docker not available; cannot start openldap"
    return 1
  fi
  docker rm -f openldap > /dev/null 2>&1 || true
  docker run -d \
    --name openldap \
    -p 389:389 \
    -e LDAP_ORGANISATION="Example Inc" \
    -e LDAP_DOMAIN="example.org" \
    -e LDAP_ADMIN_PASSWORD="admin" \
    --rm \
    osixia/openldap:1.5.0 > /dev/null

  echo "Waiting for OpenLDAP to be ready..."
  for i in $(seq 1 60); do
    if ldapsearch -x -H ldap://127.0.0.1:389 \
        -D "cn=admin,dc=example,dc=org" -w admin \
        -b "dc=example,dc=org" -s base "(objectClass=*)" > /dev/null 2>&1; then
      echo "OpenLDAP is ready."
      return 0
    fi
    sleep 1
  done
  echo "WARNING: OpenLDAP did not become healthy within 60 seconds"
  docker logs openldap | tail -50
  return 1
}

start_openldap

# ─────────────────────────────────────────────────────────
# 预置 OU 与账号
# ─────────────────────────────────────────────────────────
ldapadd -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin <<'EOF' > /dev/null 2>&1
dn: ou=ServiceAccounts,dc=example,dc=org
objectClass: organizationalUnit
ou: ServiceAccounts

dn: ou=DynamicUsers,dc=example,dc=org
objectClass: organizationalUnit
ou: DynamicUsers
EOF

# Static role 用的三个账号
for i in 1 2 3; do
  ldapadd -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin <<EOF > /dev/null 2>&1
dn: cn=app${i},ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: app${i}
sn: App${i}
userPassword: initial-pass-${i}
EOF
done

# Library 池子的三个账号
for i in 1 2 3; do
  ldapadd -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin <<EOF > /dev/null 2>&1
dn: cn=svc-ops-${i},ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: svc-ops-${i}
sn: Ops${i}
userPassword: ops-initial-pass-${i}
EOF
done

# 等 vault 装完
wait "$INSTALL_VAULT_PID"

# 启动 Vault Dev
start_vault_dev

# 启用 ldap/ 引擎（学员自己 enable 也行；这里不预启，让 step1 完整体验）
# 留给 step1 操作

cd /root
finish_setup
