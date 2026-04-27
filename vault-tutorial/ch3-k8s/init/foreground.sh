#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-90 秒"
echo "  (后台会装 Vault、装 k3s、配 manager SA、启 Vault)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已启动："
echo "   • k3s 单节点集群: $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1, $2, $5}')"
echo "   • Vault $(vault version 2>/dev/null | head -1 | awk '{print $2}') (Dev 模式)"
echo ""
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo "📂 KUBECONFIG=$KUBECONFIG"
echo ""
echo "🔧 Vault kubernetes/ 引擎已启用并连接到 k3s"
echo "   • Manager SA: vault-manager (in vault-system)"
echo "   • 预置: viewer-sa + pod-reader Role + viewer-binding (in default)"
echo ""
echo "👉 按右侧 step1 开始。"
