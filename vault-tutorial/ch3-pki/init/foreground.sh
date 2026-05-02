#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会装 Vault + openssl/jq，并启动 Vault Dev)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/pki-lab
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已启动："
echo "   • Vault $(vault version 2>/dev/null | head -1 | awk '{print $2}') (Dev 模式)"
echo "   • openssl $(openssl version 2>/dev/null | awk '{print $2}')"
echo ""
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo "📂 工作目录: $(pwd)"
echo ""
echo "👉 从 Step 1 开始：你将从零启用 pki/ 引擎、生成 Root CA。"
echo ""
