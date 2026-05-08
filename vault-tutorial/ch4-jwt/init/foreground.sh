#!/bin/bash

echo "================================================="
echo "  正在为你准备 JWT/OIDC Auth 实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会等待 kubeadm 单节点集群就绪、安装 Vault 与 jq)"
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
echo "环境已就绪。"
echo ""
echo "Vault: $(vault version | head -1 | awk '{print $2}')"
echo "kubectl: $(kubectl version --client=true --output=yaml 2>/dev/null | awk '/gitVersion:/ {print $2; exit}') client"
echo "Kubernetes: 单节点 kubeadm 集群已就绪"
echo "VAULT_ADDR=$VAULT_ADDR"
echo "VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo ""
echo "接下来按照右侧实验步骤操作即可。"
echo ""
echo "本实验使用真实 Kubernetes ServiceAccount Token；"
echo "Vault 运行在 controlplane 主机的 Dev 模式中，root token 固定为 root。"