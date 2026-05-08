#!/bin/bash

echo "================================================="
echo "  正在为你准备 service_registration 实验环境..."
echo "  请稍候，预计需要 60-120 秒"
echo "  (后台并行：等待 K8s 节点就绪、安装 vault/consul/helm、预拉 vault 镜像)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
if [ -f /etc/profile.d/kubernetes.sh ]; then
  source /etc/profile.d/kubernetes.sh
fi
if [ -f /etc/profile.d/vault.sh ]; then
  source /etc/profile.d/vault.sh
fi

clear
echo "✅ service_registration 实验环境已就绪。"
echo ""
echo "本实验前 2 步使用宿主机进程演示 Consul 模式，后 2 步用 Helm 把"
echo "HA Vault 部署到 Kubernetes 演示 Kubernetes 模式。"
echo ""
echo "── 宿主机 Consul 演示资源 ────────────────────────────────"
echo "  /root/vault-1.hcl ~ /root/vault-3.hcl  3 节点 Vault 配置"
echo "    - node-1 (API 8200, cluster 8201): bootstrap 节点，无 retry_join"
echo "    - node-2 (API 8210, cluster 8211): retry_join → 8200"
echo "    - node-3 (API 8220, cluster 8221): retry_join → 8200"
echo "    每份配置都包含 service_registration \"consul\" { address = \"127.0.0.1:8500\" }"
echo ""
echo "  ./start-consul.sh        启动 Consul dev agent (HTTP 8500, DNS 8600)"
echo "  ./start-node.sh <1|2|3>  启动指定 Vault 节点"
echo "  ./stop-host-vaults.sh    step3 之前停掉宿主机 Vault 进程释放资源"
echo ""
echo "── Kubernetes 演示资源 ───────────────────────────────────"
echo "  Killercoda 已就绪：kubeadm 单节点 K8s + kubectl + helm"
echo "  helm repo 已配置：hashicorp → https://helm.releases.hashicorp.com"
echo ""
echo "👉 按右侧步骤依序执行即可。"
