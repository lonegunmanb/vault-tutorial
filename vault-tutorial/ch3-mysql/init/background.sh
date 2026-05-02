#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq default-mysql-client jq > /dev/null 2>&1

start_mysql() {
  if ! command -v docker > /dev/null 2>&1; then
    echo "ERROR: docker not available, cannot start mysql"
    return 1
  fi

  docker rm -f learn-mysql > /dev/null 2>&1 || true
  docker run -d \
    --name learn-mysql \
    -e MYSQL_ROOT_PASSWORD=rootpassword \
    -e MYSQL_DATABASE=appdb \
    -p 3306:3306 \
    --rm \
    mysql:8.0 --default-authentication-plugin=mysql_native_password > /dev/null

  echo "Waiting for MySQL to be ready..."
  for i in $(seq 1 90); do
    if docker exec learn-mysql mysqladmin ping -h 127.0.0.1 -uroot -prootpassword --silent > /dev/null 2>&1; then
      echo "MySQL is ready."
      return 0
    fi
    sleep 1
  done

  echo "ERROR: MySQL did not become ready within 90 seconds"
  docker logs learn-mysql || true
  return 1
}

seed_mysql() {
  docker exec -i learn-mysql mysql -uroot -prootpassword <<'SQL' > /tmp/mysql-seed.log 2>&1
CREATE DATABASE IF NOT EXISTS appdb;
CREATE DATABASE IF NOT EXISTS fooapp_alpha;

CREATE TABLE IF NOT EXISTS appdb.kv (
  k varchar(64) PRIMARY KEY,
  v varchar(64) NOT NULL
);
INSERT INTO appdb.kv (k, v) VALUES ('hello', 'world'), ('vault', 'rocks')
  ON DUPLICATE KEY UPDATE v = VALUES(v);

CREATE TABLE IF NOT EXISTS fooapp_alpha.audit (
  id int PRIMARY KEY,
  note varchar(128) NOT NULL
);
INSERT INTO fooapp_alpha.audit (id, note) VALUES (1, 'wildcard grant works')
  ON DUPLICATE KEY UPDATE note = VALUES(note);

CREATE USER IF NOT EXISTS 'vaultadmin'@'%' IDENTIFIED BY 'vaultadmin';
CREATE USER IF NOT EXISTS 'legacy_app'@'%' IDENTIFIED BY 'legacy-pass';

GRANT CREATE USER ON *.* TO 'vaultadmin'@'%';
GRANT SELECT ON appdb.* TO 'vaultadmin'@'%' WITH GRANT OPTION;
GRANT SELECT ON `fooapp\_%`.* TO 'vaultadmin'@'%' WITH GRANT OPTION;
GRANT SELECT ON appdb.* TO 'legacy_app'@'%';
FLUSH PRIVILEGES;
SQL
}

start_mysql
seed_mysql

if ! docker exec -i learn-mysql mysql -uroot -prootpassword -Nse "SELECT COUNT(*) FROM mysql.user WHERE user IN ('vaultadmin','legacy_app');" 2>/dev/null | grep -q '^2$'; then
  echo "ERROR: failed to seed MySQL users. mysql log:"
  cat /tmp/mysql-seed.log
fi

wait "$INSTALL_VAULT_PID"
start_vault_dev

cd /root
finish_setup
