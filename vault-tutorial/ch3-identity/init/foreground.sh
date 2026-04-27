#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 20-30 秒"
echo "  (后台会自动安装并以 Dev 模式启动 Vault 1.19.2)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。"
