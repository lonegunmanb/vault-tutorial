#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Integrated Storage 实验环境准备就绪。"
echo "已为 4 个节点预置 vault.hcl：/root/vault-1.hcl ~ /root/vault-4.hcl"
echo "  - node-1 (API 8200, cluster 8201): 作为 bootstrap 节点，无 retry_join"
echo "  - node-2 (API 8210, cluster 8211): 通过 retry_join 自动加入 node-1"
echo "  - node-3 (API 8220, cluster 8221): 通过 retry_join 自动加入 node-1"
echo "  - node-4 (API 8230, cluster 8231): 通过 retry_join 自动加入 node-1（在 Step 2 启动）"
echo ""
echo "便捷启动脚本：./start-node.sh <1|2|3|4>"
echo "VAULT_ADDR 默认 = http://127.0.0.1:8200（指向 node-1）"
echo ""
echo "Vault 进程目前均未启动；请按步骤逐一手动拉起。"
