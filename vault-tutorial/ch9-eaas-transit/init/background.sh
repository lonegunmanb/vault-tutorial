#!/bin/bash
set +e

# ─── 全量日志 ──────────────────────────────────────────────
# 把 stdout/stderr 都重定向到 /var/log/eaas-init.log，并用带时间戳的 xtrace
# 打印每条命令；卡住时学员可 `tail -f /var/log/eaas-init.log` 直接看到
# 当前停在哪一行。
LOG=/var/log/eaas-init.log
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
type install_vault finish_setup start_vault_dev || {
  echo "FATAL: setup-common.sh did not define expected helpers"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# 先把 apt 依赖装齐（包含 install_vault 内部可能要用的 unzip），避免 install_vault
# 在后台再起一个 apt-get 与本进程争抢 /var/lib/dpkg/lock-frontend 而无限等待。
# 不再通过 apt 安装 golang-go：Ubuntu 22.04 上的 golang-go 是 1.18，无法满足
# go.mod 中的 `go 1.22` directive；改用官方二进制 tarball 安装一份 1.22.x。
stage "apt-get update"
apt-get update -qq
stage "apt-get install unzip jq curl postgresql-client"
apt-get install -y -qq unzip jq curl postgresql-client

stage "start install_vault (background)"
install_vault > /var/log/install-vault.log 2>&1 &
INSTALL_VAULT_PID=$!

# 并行安装 Go 1.22.x（官方 tarball ~70MB，比 apt 的 golang-go 元包快得多）。
install_go() {
  if command -v go > /dev/null 2>&1 && go version 2>/dev/null | grep -q 'go1.22'; then
    return 0
  fi
  curl --connect-timeout 10 --max-time 180 -fsSL \
    https://go.dev/dl/go1.22.10.linux-amd64.tar.gz -o /tmp/go.tgz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}
stage "start install_go (background)"
install_go > /var/log/install-go.log 2>&1 &
INSTALL_GO_PID=$!

stage "wait install_vault"
wait "$INSTALL_VAULT_PID"; echo "install_vault rc=$?"
stage "wait install_go"
wait "$INSTALL_GO_PID"; echo "install_go rc=$?"
command -v vault && vault version || echo "vault MISSING"
command -v go && go version || echo "go MISSING"

stage "start_vault_dev"
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 与官方 docker-compose.yaml 中的 vault-configure 容器对齐：
# 启用 transit、创建一把 payments 密钥、把 deletion_allowed 调成 true 以便
# 学员在 finish 中自由清理。
stage "enable transit + create payments key"
vault secrets enable transit
vault write -force transit/keys/payments
vault write transit/keys/payments/config deletion_allowed=true

# Postgres 16：与官方 docker-compose.yaml 一致的口令、库名。
# Killercoda Ubuntu 容器自带 docker，setup-common.sh 也一直用这种方式起 Postgres。
stage "docker run learn-postgres"
docker rm -f learn-postgres > /dev/null 2>&1 || true
docker run -d --name learn-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres-admin-password \
  -e POSTGRES_DB=payments \
  -p 5432:5432 \
  --rm \
  postgres:16

stage "wait postgres ready"
for i in $(seq 1 60); do
  if docker exec learn-postgres pg_isready -U postgres -d payments > /dev/null 2>&1; then
    echo "postgres ready after ${i}s"
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

stage "go mod tidy + build"
mkdir -p /root/eaas-app
cd /root/eaas-app
# go.mod 与 app.go 已通过 assets 拷贝到这里
GOPROXY=https://proxy.golang.org,direct go mod tidy > /var/log/go-tidy.log 2>&1
echo "go mod tidy rc=$?"
go build -o app . > /var/log/go-build.log 2>&1
echo "go build rc=$?"
ls -l /root/eaas-app/app || echo "app binary MISSING"

cd /root
stage "finish_setup (touch /tmp/.setup-done)"
finish_setup
stage "background.sh DONE"
