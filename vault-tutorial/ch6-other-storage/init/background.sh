#!/bin/bash
set +e

source /root/setup-common.sh

# 安装 vault 与 postgresql-client（仅 client，server 在 step3 用 docker 跑以避免 systemd 依赖）
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v psql > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq postgresql-client > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

# 三份 vault.hcl，分别对应 step1/step2/step3
mkdir -p /opt/vault/file-data
chmod 700 /opt/vault/file-data

cat > /root/vault-file.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"

api_addr      = "http://127.0.0.1:8200"

storage "file" {
  path = "/opt/vault/file-data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
EOF

cat > /root/vault-inmem.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"

api_addr      = "http://127.0.0.1:8200"

storage "inmem" {}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
EOF

cat > /root/vault-pg.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"

api_addr      = "http://127.0.0.1:8200"

storage "postgresql" {
  connection_url = "postgres://vault:vaultpw@127.0.0.1:5432/vault?sslmode=disable"
  table          = "vault_kv_store"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
EOF

# 默认 VAULT_ADDR
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

# Step3 用：官方 schema SQL 文件
cat > /root/vault-pg-schema.sql <<'EOF'
CREATE TABLE vault_kv_store (
  parent_path TEXT COLLATE "C" NOT NULL,
  path        TEXT COLLATE "C",
  key         TEXT COLLATE "C",
  value       BYTEA,
  CONSTRAINT pkey PRIMARY KEY (path, key)
);

CREATE INDEX parent_path_idx ON vault_kv_store (parent_path);
EOF

# Step3 用：拉起一个本地 postgres（使用官方 docker 镜像，避免 systemd 依赖）。
# 这里只准备拉取脚本，等学员到 Step3 才执行，避免 background 阶段下载延迟。
cat > /root/start-postgres.sh <<'EOF'
#!/bin/bash
# 启动一个本地 PostgreSQL 实例供 Vault 后端使用。
if ! command -v docker > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq docker.io > /dev/null 2>&1
fi
docker rm -f vault-pg > /dev/null 2>&1
docker run -d --name vault-pg \
  -e POSTGRES_USER=vault \
  -e POSTGRES_PASSWORD=vaultpw \
  -e POSTGRES_DB=vault \
  -p 127.0.0.1:5432:5432 \
  postgres:16-alpine > /dev/null

# 等待 postgres ready
for i in $(seq 1 30); do
  if PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault -c 'SELECT 1' > /dev/null 2>&1; then
    echo "PostgreSQL ready."
    exit 0
  fi
  sleep 1
done
echo "WARNING: PostgreSQL did not become ready in time."
exit 1
EOF
chmod +x /root/start-postgres.sh

# 便捷启动 Vault 脚本
cat > /root/start-vault.sh <<'EOF'
#!/bin/bash
# 用法：./start-vault.sh <file|inmem|pg>
mode=$1
if [ -z "$mode" ]; then
  echo "用法：$0 <file|inmem|pg>"
  exit 1
fi
# 先停掉已有的 vault 进程
pkill -f 'vault server' > /dev/null 2>&1
sleep 1
nohup vault server -config=/root/vault-${mode}.hcl > /var/log/vault-${mode}.log 2>&1 &
echo "vault (${mode} backend) 已启动，日志：/var/log/vault-${mode}.log"
EOF
chmod +x /root/start-vault.sh

cd /root
finish_setup
