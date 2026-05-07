#!/bin/bash
set +e

source /root/setup-common.sh

# 并行：装 vault + jq + docker + awscli + 预拉 LocalStack 镜像
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

if ! command -v docker > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq docker.io > /dev/null 2>&1
fi

if ! command -v socat > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq socat > /dev/null 2>&1
fi

install_awscli &
INSTALL_AWS_PID=$!

docker pull localstack/localstack:3 > /dev/null 2>&1 &
PULL_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_AWS_PID" 2>/dev/null
wait "$PULL_PID" 2>/dev/null

# 准备 raft 数据目录
mkdir -p /opt/vault/data
chmod 700 /opt/vault/data

# 基线 vault.hcl：仅 storage + listener，没有 seal 块。学员在 Step 2 追加 seal "awskms"。
cat > /root/vault.hcl <<'EOF'
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

default_lease_ttl = "168h"
max_lease_ttl     = "720h"
EOF

# Vault CLI 默认地址（HTTP）。学员后续不需要改 VAULT_ADDR——本实验全程明文 HTTP，
# 让注意力集中在 seal 而非 listener TLS 上。
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

# 持久化 LocalStack 默认凭据：root 凭据是 test/test
cat > /etc/profile.d/aws.sh <<'EOF'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
EOF
chmod +x /etc/profile.d/aws.sh
grep -q "AWS_ACCESS_KEY_ID=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/aws.sh >> /root/.bashrc

cd /root
finish_setup
