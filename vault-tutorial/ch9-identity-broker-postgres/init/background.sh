#!/bin/bash
set +e

source /root/setup-common.sh

# 并行：装 vault、装 jq、装 docker（K8s 镜像通常已带 docker，幂等）、装 awscli + awslocal
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq curl postgresql-client > /dev/null 2>&1

if ! command -v docker > /dev/null 2>&1; then
  apt-get install -y -qq docker.io > /dev/null 2>&1
fi

install_awscli &
INSTALL_AWS_PID=$!

# 预拉镜像
docker pull localstack/localstack:3 > /dev/null 2>&1 &
PULL_LS_PID=$!
docker pull postgres:16 > /dev/null 2>&1 &
PULL_PG_PID=$!

# 等 K8s 就绪
if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f /root/.kube/config ]; then
    export KUBECONFIG=/root/.kube/config
  elif [ -f /etc/kubernetes/admin.conf ]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

cat > /etc/profile.d/kubernetes.sh <<EOF
export KUBECONFIG='${KUBECONFIG:-/root/.kube/config}'
EOF
chmod +x /etc/profile.d/kubernetes.sh
grep -q "KUBECONFIG=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/kubernetes.sh >> /root/.bashrc

echo "Waiting for Kubernetes to be ready..."
for i in $(seq 1 120); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    echo "Kubernetes ready."
    break
  fi
  sleep 1
done

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_AWS_PID" 2>/dev/null
wait "$PULL_LS_PID" 2>/dev/null
wait "$PULL_PG_PID" 2>/dev/null

# 启动 Vault Dev (root token = root)
start_vault_dev

# 启动 PostgreSQL (postgres:16, superuser=root/rootpassword, 5432)
start_postgres

# 在 PG 里预置：
#   1) vaultadmin (CREATEROLE) —— 给 Vault 的 database/config 用
#   2) demo schema + demo.kv 两条业务数据
seed_pg() {
  docker exec -i learn-postgres psql -U root -d postgres -v ON_ERROR_STOP=0 <<'SQL' > /tmp/pg-seed.log 2>&1
CREATE ROLE vaultadmin WITH LOGIN PASSWORD 'vaultadmin' CREATEROLE;

CREATE SCHEMA IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.kv (k text PRIMARY KEY, v text);
INSERT INTO demo.kv (k,v) VALUES
  ('greeting','hello-from-vault-broker'),
  ('demo','identity-brokering')
  ON CONFLICT (k) DO NOTHING;

GRANT USAGE ON SCHEMA demo TO vaultadmin WITH GRANT OPTION;
GRANT SELECT ON ALL TABLES IN SCHEMA demo TO vaultadmin WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES IN SCHEMA demo GRANT SELECT ON TABLES TO vaultadmin WITH GRANT OPTION;
SQL
}

count_seeded() {
  docker exec -i learn-postgres psql -U root -d postgres -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname='vaultadmin';" 2>/dev/null
}

for attempt in 1 2 3 4 5; do
  seed_pg
  if [ "$(count_seeded)" = "1" ]; then
    echo "Seeded PG role vaultadmin on attempt $attempt."
    break
  fi
  sleep 2
done

# 启动 LocalStack（IAM + STS 服务，端口 4566）
docker rm -f localstack > /dev/null 2>&1 || true
docker run -d --name localstack \
  -p 4566:4566 \
  -e SERVICES=iam,sts \
  -e DEBUG=0 \
  localstack/localstack:3 > /dev/null

echo "Waiting for LocalStack IAM/STS ready..."
for i in $(seq 1 60); do
  if curl -s http://127.0.0.1:4566/_localstack/health 2>/dev/null \
       | jq -e '.services.iam == "available" and .services.sts == "available"' > /dev/null 2>&1; then
    echo "LocalStack ready."
    break
  fi
  sleep 1
done

# 持久化 AWS CLI 默认凭据（LocalStack 接受任意签名，但 CLI 自身要看到 key）
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
