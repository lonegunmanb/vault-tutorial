#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "audit devices 实验环境准备就绪。"
echo "已预置 /root/vault.hcl（单节点 raft + 明文 HTTP）。"
echo "便捷脚本：./start-vault.sh、./stop-vault.sh"
echo "rsyslog 已运行，local0 facility 引到 /var/log/vault/vault-audit.syslog。"
