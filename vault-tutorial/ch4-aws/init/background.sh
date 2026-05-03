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

# 持久化 AWS CLI 默认凭据：LocalStack 的 root 凭据是 test/test
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
