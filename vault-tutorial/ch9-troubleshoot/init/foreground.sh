#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "故障排查实验环境准备就绪。"
echo "已预置两份配置：/root/vault-broken.hcl（情景一'坏'配置）、/root/vault-fixed.hcl（情景一'好'配置）。"
echo "便捷脚本：./start-vault.sh <config-file>、./stop-vault.sh"
