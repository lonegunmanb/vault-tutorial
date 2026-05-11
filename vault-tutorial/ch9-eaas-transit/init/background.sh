#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

# go 用于编译 Gin 应用；jq / curl 用于直接打 Vault 与应用的 HTTP 接口；
# postgresql-client 提供 psql，便于学员在 step1 直接看数据库里的密文。
apt-get update -qq && apt-get install -y -qq golang-go jq curl postgresql-client > /dev/null 2>&1

wait "$INSTALL_VAULT_PID"

start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 与官方 docker-compose.yaml 中的 vault-configure 容器对齐：
# 启用 transit、创建一把 payments 密钥、把 deletion_allowed 调成 true 以便
# 学员在 finish 中自由清理。
vault secrets enable transit 2>/dev/null
vault write -force transit/keys/payments > /dev/null 2>&1
vault write transit/keys/payments/config deletion_allowed=true > /dev/null 2>&1

# Postgres 16：与官方 docker-compose.yaml 一致的口令、库名。
# Killercoda Ubuntu 容器自带 docker，setup-common.sh 也一直用这种方式起 Postgres。
docker rm -f learn-postgres > /dev/null 2>&1 || true
docker run -d --name learn-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres-admin-password \
  -e POSTGRES_DB=payments \
  -p 5432:5432 \
  --rm \
  postgres:16 > /dev/null 2>&1

# 等 Postgres 就绪
for i in $(seq 1 60); do
  if docker exec learn-postgres pg_isready -U postgres -d payments > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# 写入与官方 schema.sql 完全一致的建表 DDL（应用启动时也会再做一次幂等的
# CREATE TABLE IF NOT EXISTS，这里预先建好只是为了让 step1 在不启动应用前
# 也能直接用 psql 看到表结构）。
PGPASSWORD=postgres-admin-password psql -h 127.0.0.1 -U postgres -d payments \
  -v ON_ERROR_STOP=1 <<'SQL' > /var/log/pg-init.log 2>&1
SET TIME ZONE 'UTC';
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS payments (
    id         VARCHAR(255) PRIMARY KEY NOT NULL,
    name       VARCHAR(255)             NOT NULL,
    cc_info    VARCHAR(255)             NOT NULL,
    created_at TIMESTAMP                NOT NULL
);
SQL

# 预置便捷连接环境变量；用 PAGER=cat 关闭 psql 分页器，避免课堂上 less 卡住终端
cat >> /etc/profile.d/vault.sh <<'EOF'
export PGPASSWORD=postgres-admin-password
export PGHOST=127.0.0.1
export PGUSER=postgres
export PGDATABASE=payments
export DATABASE_URL='postgres://postgres:postgres-admin-password@127.0.0.1:5432/payments?sslmode=disable'
export PAGER=cat
EOF

# 预先把 Gin 应用的依赖下载好、二进制编译好，避免课堂上等 go mod tidy 拉网。
mkdir -p /root/eaas-app
cd /root/eaas-app
# go.mod 与 app.go 已通过 assets 拷贝到这里
GOPROXY=https://proxy.golang.org,direct go mod tidy > /var/log/go-tidy.log 2>&1
go build -o app . > /var/log/go-build.log 2>&1
ls -l /root/eaas-app/app > /var/log/go-build-out.log 2>&1

cd /root
finish_setup
