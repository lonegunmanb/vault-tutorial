#!/bin/bash

echo "================================================="
echo "  正在为你准备 Vault Identity Broker 实验环境..."
echo "  请稍候，预计需要 60-120 秒"
echo "  (后台会启动 Vault Dev + PostgreSQL + LocalStack + 等待 K8s 就绪)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
if [ -f /etc/profile.d/aws.sh ]; then
  source /etc/profile.d/aws.sh
fi
if [ -f /etc/profile.d/kubernetes.sh ]; then
  source /etc/profile.d/kubernetes.sh
fi

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 Vault $(vault version | head -1 | awk '{print $2}')，AWS CLI $(aws --version 2>&1 | awk '{print $1}')，kubectl，jq，psql"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo "🐘 PostgreSQL: 127.0.0.1:5432  (root/rootpassword 是 superuser；vaultadmin/vaultadmin 给 Vault 用)"
echo "☁️  LocalStack (IAM+STS): http://127.0.0.1:4566   account=000000000000"
echo "☸️  Kubernetes：单节点 kubeadm，已就绪"
echo ""
echo "👉 接下来按照右侧实验步骤操作。"
echo ""
echo "ℹ️ 第一步走 AWS IAM → PostgreSQL；第二步会复用 第一步留下来的"
echo "   database/config/postgres-broker 与 database/roles/readonly，只换 Phase 1 的认证方法。"
