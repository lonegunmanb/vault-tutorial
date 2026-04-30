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
# 一次性 LDIF + ldapadd -c：osixia 容器在 base DN 已上线后还会跑一会儿 bootstrap，
# 期间个别写入会被拒。-c 让 ldapadd 遇到任何条目错误（包括重复执行时的 "Already exists"）
# 都继续往后走，最后用 ldapsearch 校验条目数 + 必要时重试，避免 step1 出现 "只看到 2 个 cn:" 的情况。
# ─────────────────────────────────────────────────────────
seed_ldap_entries() {
  ldapadd -c -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin <<'EOF'
dn: ou=ServiceAccounts,dc=example,dc=org
objectClass: organizationalUnit
ou: ServiceAccounts

dn: ou=DynamicUsers,dc=example,dc=org
objectClass: organizationalUnit
ou: DynamicUsers

dn: cn=app1,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: app1
sn: App1
userPassword: initial-pass-1

dn: cn=app2,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: app2
sn: App2
userPassword: initial-pass-2

dn: cn=app3,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: app3
sn: App3
userPassword: initial-pass-3

dn: cn=svc-ops-1,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: svc-ops-1
sn: Ops1
userPassword: ops-initial-pass-1

dn: cn=svc-ops-2,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: svc-ops-2
sn: Ops2
userPassword: ops-initial-pass-2

dn: cn=svc-ops-3,ou=ServiceAccounts,dc=example,dc=org
objectClass: inetOrgPerson
cn: svc-ops-3
sn: Ops3
userPassword: ops-initial-pass-3
EOF
}

count_seeded() {
  ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin \
    -b "ou=ServiceAccounts,dc=example,dc=org" \
    "(objectClass=inetOrgPerson)" cn 2>/dev/null \
    | grep -c '^cn:'
}

for attempt in 1 2 3 4 5; do
  seed_ldap_entries > /tmp/ldapadd.log 2>&1 || true
  n=$(count_seeded)
  if [ "$n" -ge 6 ]; then
    echo "Seeded $n LDAP entries on attempt $attempt."
    break
  fi
  echo "Seed attempt $attempt got only $n/6 entries; retrying in 2s..."
  sleep 2
done

if [ "$(count_seeded)" -lt 6 ]; then
  echo "ERROR: failed to seed all 6 LDAP entries after retries. ldapadd log:"
  cat /tmp/ldapadd.log
fi

# 等 vault 装完
wait "$INSTALL_VAULT_PID"

# 启动 Vault Dev
start_vault_dev

# 启用 ldap/ 引擎（学员自己 enable 也行；这里不预启，让 step1 完整体验）
# 留给 step1 操作

cd /root
finish_setup
