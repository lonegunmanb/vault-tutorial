#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "user lockout 实验环境准备就绪。"
echo "已预置 /root/vault.hcl，其中 user_lockout \"userpass\" 设为："
echo "  lockout_threshold = 3, lockout_duration = 1m, lockout_counter_reset = 1m"
echo "便捷脚本：./start-vault.sh、./stop-vault.sh"
