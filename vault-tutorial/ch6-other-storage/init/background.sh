#!/bin/bash
set +e

source /root/setup-common.sh

# 并行安装 vault / 拉取 LocalStack 镜像 / 装 awscli + awslocal
install_vault &
INSTALL_VAULT_PID=$!

install_awscli &
INSTALL_AWS_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

if ! command -v psql > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq postgresql-client > /dev/null 2>&1
fi

if ! command -v docker > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq docker.io > /dev/null 2>&1
fi

# 提前预热 LocalStack 镜像，让 step4 / step5 启动时秒级响应
docker pull localstack/localstack:3 > /dev/null 2>&1 &
PULL_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_AWS_PID" 2>/dev/null
wait "$PULL_PID" 2>/dev/null

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

# Step4：S3 后端，指向本地 LocalStack（本地 AWS API 兼容服务的 :4566 端点）
cat > /root/vault-s3.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"

api_addr      = "http://127.0.0.1:8200"

storage "s3" {
  access_key          = "test"
  secret_key          = "test"
  bucket              = "vault-data"
  endpoint            = "http://127.0.0.1:4566"
  region              = "us-east-1"
  s3_force_path_style = "true"
  disable_ssl         = "true"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
EOF

# Step5：DynamoDB 后端，同样指向本地 LocalStack
cat > /root/vault-dynamodb.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"

api_addr      = "http://127.0.0.1:8200"

storage "dynamodb" {
  ha_enabled = "true"
  access_key = "test"
  secret_key = "test"
  region     = "us-east-1"
  endpoint   = "http://127.0.0.1:4566"
  table      = "vault-data"
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

# 默认 AWS 凭据（指向 LocalStack 的 root 凭据 test/test）
cat > /etc/profile.d/aws.sh <<'EOF'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
EOF
chmod +x /etc/profile.d/aws.sh
grep -q "AWS_ACCESS_KEY_ID=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/aws.sh >> /root/.bashrc

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
# 用法：./start-vault.sh <file|inmem|pg|s3|dynamodb>
mode=$1
if [ -z "$mode" ]; then
  echo "用法：$0 <file|inmem|pg|s3|dynamodb>"
  exit 1
fi
# 先停掉已有的 vault 进程：先 SIGTERM 给一秒优雅退出，再 SIGKILL 兜底，
# 然后**真正等到 :8200 空闲**再拉新进程，避免端口冲突导致新进程秒退、
# 学员仍然连到旧进程的“已 initialized”状态上。
pkill -f 'vault server' > /dev/null 2>&1
sleep 1
pkill -9 -f 'vault server' > /dev/null 2>&1
for i in $(seq 1 10); do
  if ! ss -ltn 2>/dev/null | grep -q ':8200 '; then
    break
  fi
  sleep 1
done
nohup vault server -config=/root/vault-${mode}.hcl > /var/log/vault-${mode}.log 2>&1 &
# 等 :8200 真正起来再返回
for i in $(seq 1 15); do
  if ss -ltn 2>/dev/null | grep -q ':8200 '; then
    break
  fi
  sleep 1
done
echo "vault (${mode} backend) 已启动，日志：/var/log/vault-${mode}.log"
EOF
chmod +x /root/start-vault.sh

# 启动 LocalStack（本地 AWS API 兼容服务，监听 :4566）。
# 学员到 step4 才执行；这里只准备脚本。
cat > /root/start-localstack.sh <<'EOF'
#!/bin/bash
# 启动一个本地 LocalStack 实例供 Vault s3 / dynamodb 后端使用。
docker rm -f localstack > /dev/null 2>&1
docker run -d --name localstack -p 4566:4566 -e SERVICES=s3,dynamodb localstack/localstack:3 > /dev/null

# 等 LocalStack 健康
for i in $(seq 1 30); do
  if curl -fs http://127.0.0.1:4566/_localstack/health > /dev/null 2>&1; then
    echo "localstack ready."
    exit 0
  fi
  sleep 1
done
echo "WARNING: localstack did not become ready in time."
exit 1
EOF
chmod +x /root/start-localstack.sh

cd /root
finish_setup
