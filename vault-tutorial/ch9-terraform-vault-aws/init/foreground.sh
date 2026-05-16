#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-120 秒"
echo "  (后台会安装 Vault、Terraform、awscli v2、Docker，"
echo "   启动 Vault dev server 与 LocalStack，并生成两个 Terraform 工作区)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/terraform-vault-aws-localstack
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')，terraform $(terraform version -json | jq -r '.terraform_version')，aws CLI v2，docker，jq"
echo "🌐 Vault：$VAULT_ADDR  (root token=root)"
echo "☁️  LocalStack：127.0.0.1:4566  (IAM / STS / EC2，ENFORCE_IAM=1)"
echo "📁 Admin 工作区：/root/terraform-vault-aws-localstack/vault-admin-workspace"
echo "📁 Operator 工作区：/root/terraform-vault-aws-localstack/operator-workspace"
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。"