#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq ldap-utils jq > /dev/null 2>&1

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

seed_ldap_entries() {
  ldapadd -c -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin <<'EOF'
dn: ou=People,dc=example,dc=org
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=example,dc=org
objectClass: organizationalUnit
ou: Groups

dn: uid=vault-reader,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
cn: Vault Reader
sn: Reader
uid: vault-reader
userPassword: reader-pass

dn: uid=alice,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
cn: Alice Doe
sn: Doe
uid: alice
employeeType: Employee
userPassword: alice-pass

dn: uid=bob,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
cn: Bob Smith
sn: Smith
uid: bob
employeeType: Employee
userPassword: bob-pass

dn: uid=carol,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
cn: Carol Contractor
sn: Contractor
uid: carol
employeeType: Contractor
userPassword: carol-pass

dn: cn=dev,ou=Groups,dc=example,dc=org
objectClass: groupOfNames
cn: dev
member: uid=alice,ou=People,dc=example,dc=org
member: uid=bob,ou=People,dc=example,dc=org

dn: cn=ops,ou=Groups,dc=example,dc=org
objectClass: groupOfNames
cn: ops
member: uid=alice,ou=People,dc=example,dc=org

dn: cn=contractors,ou=Groups,dc=example,dc=org
objectClass: groupOfNames
cn: contractors
member: uid=carol,ou=People,dc=example,dc=org
EOF
}

count_people() {
  ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin \
    -b "ou=People,dc=example,dc=org" \
    "(objectClass=inetOrgPerson)" uid 2>/dev/null | grep -c '^uid:'
}

count_groups() {
  ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=example,dc=org" -w admin \
    -b "ou=Groups,dc=example,dc=org" \
    "(objectClass=groupOfNames)" cn 2>/dev/null | grep -c '^cn:'
}

start_openldap

for attempt in 1 2 3 4 5; do
  seed_ldap_entries > /tmp/ldap-auth-seed.log 2>&1 || true
  people=$(count_people)
  groups=$(count_groups)
  if [ "$people" -ge 4 ] && [ "$groups" -ge 3 ]; then
    echo "Seeded $people people and $groups groups on attempt $attempt."
    break
  fi
  echo "Seed attempt $attempt got people=$people groups=$groups; retrying in 2s..."
  sleep 2
done

if [ "$(count_people)" -lt 4 ] || [ "$(count_groups)" -lt 3 ]; then
  echo "ERROR: failed to seed LDAP auth entries. ldapadd log:"
  cat /tmp/ldap-auth-seed.log
fi

wait "$INSTALL_VAULT_PID"
start_vault_dev

cd /root
finish_setup