#!/bin/bash

echo "================================================="
echo "  正在准备 TLS 证书认证实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会安装 Vault、生成证书、启动 TLS Vault)"
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
echo "🔐 VAULT_CACERT=$VAULT_CACERT"
echo "🔑 VAULT_TOKEN 已写入环境变量"
echo ""
echo "📁 证书目录：/root/cert-lab"
echo "   server-ca.crt       -> 验证 Vault 服务端 TLS 证书"
echo "   client-ca.crt       -> 登记到 auth/cert 的客户端 CA"
echo "   web-client.crt/key  -> 应成功登录"
echo "   db-client.crt/key   -> CA 可信但 role 约束不匹配"
echo "   rogue-client.crt/key -> 不受信 CA，自然失败"
echo ""
echo "👉 按右侧 step1 开始。"