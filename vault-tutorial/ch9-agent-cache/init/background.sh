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

install_awscli &
INSTALL_AWS_PID=$!

docker pull localstack/localstack:3 > /dev/null 2>&1 &
PULL_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_AWS_PID" 2>/dev/null
wait "$PULL_PID" 2>/dev/null

start_vault_dev

cat > /etc/profile.d/aws.sh <<'EOF'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
EOF
chmod +x /etc/profile.d/aws.sh
grep -q "AWS_ACCESS_KEY_ID=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/aws.sh >> /root/.bashrc

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 启动 LocalStack（IAM + STS 已经够 aws/creds 用）
docker rm -f localstack > /dev/null 2>&1 || true
docker run -d --name localstack -p 4566:4566 \
  -e SERVICES=iam,sts \
  localstack/localstack:3 > /dev/null

# 等 LocalStack 健康
for i in $(seq 1 30); do
  if curl -s http://127.0.0.1:4566/_localstack/health 2>/dev/null \
      | jq -e '.services.iam == "available" and .services.sts == "available"' > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# 启用并配置 AWS 机密引擎，指向 LocalStack
vault secrets enable aws > /dev/null 2>&1 || true
vault write aws/config/root \
  access_key=test \
  secret_key=test \
  region=us-east-1 \
  iam_endpoint=http://127.0.0.1:4566 \
  sts_endpoint=http://127.0.0.1:4566 > /dev/null

# 把默认 lease 调短，方便实验观察
vault write aws/config/lease lease=10m lease_max=1h > /dev/null

# 一个最小的 IAM 内联策略：允许列 S3 桶（业务无关，纯演示）
vault write aws/roles/dev-iam \
  credential_type=iam_user \
  policy_document=-<<'EOF' > /dev/null
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListAllMyBuckets"], "Resource": "*"}
  ]
}
EOF

# 写一份 KV v2 静态机密
vault kv put secret/agent/static \
  username='static-user' \
  password='static-password-v1' > /dev/null

# AppRole + 策略：允许从 aws/creds/dev-iam 拿凭据，允许读 secret/data/agent/static
vault auth enable approle > /dev/null 2>&1 || true
vault policy write agent-cache-lab - > /dev/null <<'EOF'
path "aws/creds/dev-iam" {
  capabilities = ["read", "update"]
}
path "secret/data/agent/static" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/agent-cache-lab \
  token_policies='agent-cache-lab' \
  token_ttl='30m' \
  token_max_ttl='1h' > /dev/null

vault read -field=role_id auth/approle/role/agent-cache-lab/role-id > /root/agent-role-id
vault write -force -field=secret_id auth/approle/role/agent-cache-lab/secret-id > /root/agent-secret-id
chmod 600 /root/agent-role-id /root/agent-secret-id

# Agent 配置：cache + listener + use_auto_auth_token
mkdir -p /root/agent-cache
cat > /root/agent-cache.hcl <<'EOF'
pid_file = "/tmp/vault-agent-cache.pid"

vault {
  address = "http://127.0.0.1:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/agent-role-id"
      secret_id_file_path                 = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/root/agent-cache/auto-auth-token"
    }
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
EOF

# 启用 file 审计设备，便于学员看『请求是否真到达了 Vault Server』
vault audit enable file file_path=/root/vault-audit.log > /dev/null 2>&1 || true
chmod 644 /root/vault-audit.log 2>/dev/null || true

cd /root
finish_setup
