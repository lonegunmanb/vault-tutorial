#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (Killercoda 已提供 K8s；后台会装 Vault、配 manager SA、启 Vault)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
if [ -f /etc/profile.d/kubernetes.sh ]; then
  source /etc/profile.d/kubernetes.sh
fi

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已启动："
echo "   • kubeadm 单节点集群: $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1, $2, $5}')"
echo "   • Vault $(vault version 2>/dev/null | head -1 | awk '{print $2}') (Dev 模式)"
echo ""
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo "📂 KUBECONFIG=$KUBECONFIG"
echo ""
echo "🔧 Vault kubernetes/ 引擎已启用并连接到 Kubernetes"
echo "   • Manager SA: vault-manager (in vault-system)"
echo "   • 预置: viewer-sa + pod-reader Role + viewer-binding (in default)"
echo ""
echo "👉 按右侧 step1 开始。"
