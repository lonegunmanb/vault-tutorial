#!/bin/bash
# Foreground setup — waits for background to complete, then greets the user.

echo "等待环境初始化..."
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

echo ""
echo "✅ 环境已就绪：Vault dev 服务器（root token = root）"
echo ""
vault status
