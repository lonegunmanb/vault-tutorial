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

# 并行安装 Go 1.22.x（官方 tarball ~70MB）。Killercoda ubuntu 镜像预装了
# /usr/local/bin/go (1.18)，所以这里不依赖 ln -sf 覆盖，而是把 /usr/local/go/bin
# 直接 prepend 到 PATH，并在下面使用绝对路径调用 go。
install_go() {
  set -e
  if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version | grep -q 'go1.22'; then
    echo "go 1.22 already installed at /usr/local/go"
    return 0
  fi
  echo "downloading go1.22.10 tarball..."
  curl --connect-timeout 10 --max-time 240 -fsSL \
    https://go.dev/dl/go1.22.10.linux-amd64.tar.gz -o /tmp/go.tgz
  echo "extracting..."
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  /usr/local/go/bin/go version
}
stage "start install_go (background)"
install_go > /var/log/install-go.log 2>&1 &
INSTALL_GO_PID=$!

stage "wait install_vault"
wait "$INSTALL_VAULT_PID"; VAULT_RC=$?; echo "install_vault rc=$VAULT_RC"
stage "wait install_go"
wait "$INSTALL_GO_PID"; GO_RC=$?; echo "install_go rc=$GO_RC"
if [ "$GO_RC" -ne 0 ] || [ ! -x /usr/local/go/bin/go ]; then
  echo "FATAL: install_go failed; dumping log:"
  cat /var/log/install-go.log
  exit 1
fi
# Prepend Go 1.22 to PATH for the rest of background.sh AND for future shells.
export PATH=/usr/local/go/bin:$PATH
cat > /etc/profile.d/go.sh <<'EOF'
export PATH=/usr/local/go/bin:$PATH
EOF
chmod +x /etc/profile.d/go.sh
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
  if docker exec learn-postgres pg_isready -U postgres -d payments > /dev/null 2>&1 \
     && docker exec learn-postgres psql -U postgres -d payments -c 'SELECT 1' > /dev/null 2>&1; then
    echo "postgres ready after ${i}s"
    break
  fi
  sleep 1
done

# 写入与官方 schema.sql 完全一致的建表 DDL（应用启动时也会再做一次幂等的
# CREATE TABLE IF NOT EXISTS，这里预先建好只是为了让 step1 在不启动应用前
# 也能直接用 psql 看到表结构）。
stage "create payments table (with retry)"
for i in $(seq 1 10); do
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
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "payments table created (attempt $i)"
    break
  fi
  echo "psql attempt $i failed rc=$rc, retrying..."
  sleep 2
done

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
echo "--- go env ---"
command -v go && go version || echo "go MISSING in PATH"
echo "--- go.mod ---"
cat go.mod 2>/dev/null || echo "go.mod MISSING"
echo "--- ls /root/eaas-app ---"
ls -la /root/eaas-app
# go.mod 与 app.go 已通过 assets 拷贝到这里
GOPROXY=https://proxy.golang.org,direct go mod tidy 2>&1 | tee /var/log/go-tidy.log
echo "go mod tidy rc=${PIPESTATUS[0]}"
go build -o app . 2>&1 | tee /var/log/go-build.log
echo "go build rc=${PIPESTATUS[0]}"
ls -l /root/eaas-app/app || echo "app binary MISSING"

cd /root
stage "finish_setup (touch /tmp/.setup-done)"
finish_setup
stage "background.sh DONE"
