#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "速率限流实验环境准备就绪。"
echo "已预置 /root/vault.hcl（单节点 raft + 明文 HTTP 监听 :8200）。"
echo "便捷脚本：./start-vault.sh、./stop-vault.sh"
