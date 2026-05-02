#!/bin/bash

echo "================================================="
echo "  正在为你准备 MySQL 实验环境..."
echo "  请稍候，预计需要 60-120 秒"
echo "  (后台会自动安装 Vault、启动 MySQL 容器、预置库和账号)"
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
echo "🐬 MySQL 8 容器已启动：127.0.0.1:3306"
echo "   超级用户  : root / rootpassword      (旁路验证用)"
echo "   Vault root: vaultadmin / vaultadmin  (写入 config 后由 Vault 轮转)"
echo "   演示库    : appdb.kv，fooapp_alpha.audit"
echo ""
echo "🔧 工具：vault / mysql / jq / docker"
echo "   连 MySQL 例：mysql -h 127.0.0.1 -uroot -prootpassword"
echo ""
echo "👉 按右侧 step1 开始。"
