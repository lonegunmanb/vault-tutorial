#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "telemetry / ui 实验环境准备就绪。"
echo "已为 3 个节点预置 vault.hcl：/root/vault-1.hcl ~ /root/vault-3.hcl"
echo "  - 端口分布：node-1 (8200/8201)、node-2 (8210/8211)、node-3 (8220/8221)"
echo "  - listener 绑定 0.0.0.0，便于浏览器访问 /ui/"
echo "  - 顶层已预置 telemetry { prometheus_retention_time = \"30s\" }"
echo "便捷脚本：./start-node.sh <1|2|3>，./find-leader.sh"
