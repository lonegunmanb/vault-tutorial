#!/bin/bash
# Foreground setup — waits for background to complete, then greets the user.

echo "等待环境初始化..."
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

# These are also persisted to /etc/profile.d/vault.sh by start_vault_dev,
# so any new shell will pick them up automatically.
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

echo ""
echo "✅ 环境已就绪："
echo "   - Vault dev 服务器（root token = root）"
echo "   - Postgres 容器 learn-postgres（root / rootpassword）"
echo "   - database 引擎已挂载，readonly 角色已注册（default_ttl=1m, max_ttl=5m）"
echo ""
vault status
