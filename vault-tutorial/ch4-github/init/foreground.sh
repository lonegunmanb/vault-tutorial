#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-90 秒"
echo "  (后台会安装 Vault、Node.js、Prism 4.10.5、Nginx、openssl)"
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
echo "📦 已安装："
echo "   vault $(vault version | head -1 | awk '{print $2}')"
echo "   node  $(node --version)"
echo "   prism $(prism --version 2>/dev/null | head -1)"
echo "   nginx $(nginx -v 2>&1 | awk -F/ '{print $2}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo ""
echo "📂 /root 下已经放好 4 个素材："
ls -1 /root/{github-mock.yaml,openssl-san.cnf,nginx-fakegh.conf,setup-common.sh} 2>/dev/null
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。"
echo ""
echo "ℹ️ 本实验会让 Vault 以为自己在跟 https://api.github.com 对话——"
echo "   实际背后是 Prism + Nginx + 自签证书 + /etc/hosts 劫持出来的"
echo "   一个 'fake GitHub'。整个 4 条 GitHub REST API 都会真实跑过。"
