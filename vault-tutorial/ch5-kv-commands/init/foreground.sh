#!/bin/bash

echo "================================================="
echo "  正在为你准备 KV 专用命令实验环境..."
echo "  请稍候，预计需要 20-30 秒"
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
echo "当前已启用的机密引擎："
vault secrets list -format=table | grep -E 'Path|cubbyhole/|identity/|secret/'
echo ""
echo "你现在可以直接执行 vault kv 命令。"