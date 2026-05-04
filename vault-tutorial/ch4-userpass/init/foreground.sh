#!/bin/bash

echo "================================================="
echo "  正在准备 Userpass 认证实验环境..."
echo "  请稍候，预计需要 20-40 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

source /etc/profile.d/vault.sh
cd /root

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 Vault: $(vault version 2>/dev/null | head -1 | awk '{print $2}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo ""
echo "👉 按右侧 step1 开始。"