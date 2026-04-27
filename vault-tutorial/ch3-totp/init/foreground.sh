#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会安装 vault / oathtool / qrencode / jq)"
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
echo "📦 已安装：vault $(vault version 2>/dev/null | head -1 | awk '{print $2}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo ""
echo "🔧 工具："
echo "   oathtool   - 独立 RFC 6238 实现（验证算法等价）"
echo "   qrencode   - 把 otpauth:// URL 转成终端 QR 码"
echo "   jq / base64"
echo ""
echo "✓ totp/ 引擎已启用"
echo ""
echo "👉 按右侧 step1 开始。"
