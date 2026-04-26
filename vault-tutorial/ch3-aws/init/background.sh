#!/bin/bash
source /root/setup-common.sh

# 并行：装 vault + 装 jq + 拉 ministack 镜像，省掉串行等待
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Killercoda 的 ubuntu 镜像通常已带 docker；如果没有就装
if ! command -v docker > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq docker.io > /dev/null 2>&1
fi

# 装 awscli（用于在 step2/3 直连 ministack 验证 IAM User 的存在与消亡）
if ! command -v aws > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq awscli > /dev/null 2>&1
fi

# 提前预热拉 ministack 镜像，让 step1 启动它时秒级响应
docker pull ministackorg/ministack > /dev/null 2>&1 &
PULL_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$PULL_PID" 2>/dev/null

# start_vault_dev 内部已经等到健康才返回
start_vault_dev

# 持久化 AWS CLI 默认配置：所有终端都能直接 `aws` 命令
# - AWS_PAGER=""：禁用 less 分页，避免 killercoda terminal 卡住
# - test/test：ministack 默认 root 凭据
# - region：AWS CLI 必须有 region，否则报 NoRegion
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
