#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "service_registration 实验环境准备就绪。"
echo ""
echo "已为 3 个 Vault 节点预置 vault.hcl：/root/vault-1.hcl ~ /root/vault-3.hcl"
echo "  - node-1 (API 8200, cluster 8201): bootstrap 节点，无 retry_join"
echo "  - node-2 (API 8210, cluster 8211): retry_join → 8200"
echo "  - node-3 (API 8220, cluster 8221): retry_join → 8200"
echo ""
echo "三份配置都包含：service_registration \"consul\" { address = \"127.0.0.1:8500\" }"
echo ""
echo "便捷启动脚本："
echo "  ./start-consul.sh        # 启动 Consul dev agent (HTTP 8500, DNS 8600)"
echo "  ./start-node.sh <1|2|3>  # 启动指定 Vault 节点"
