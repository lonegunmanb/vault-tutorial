#!/bin/bash

echo "================================================="
echo "  正在为你准备 lease / unwrap / ssh / path-help 实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "环境已就绪！"
echo ""
echo "Vault 版本：$(vault version | head -1 | awk '{print $2}')"
echo ""
echo "已启用的相关机密引擎："
vault secrets list | grep -E "Path|database|ssh-otp|secret/"
echo ""
echo "database/roles/readonly："
vault read database/roles/readonly | grep -E "db_name|default_ttl|max_ttl|creation_statements" || true
echo ""
echo "你现在可以直接执行 vault 命令。"