#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会安装 Vault / Docker / AWS CLI 并拉取 MiniStack 镜像)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}'), $(docker --version | awk '{print $1, $3}' | tr -d ','), $(aws --version 2>&1 | awk '{print $1}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo "☁️  AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION  AWS_PAGER=\"\""
echo "    AWS_ACCESS_KEY_ID=test / AWS_SECRET_ACCESS_KEY=test  (MiniStack root 凭据)"
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。Step 1 会启动 MiniStack。"
