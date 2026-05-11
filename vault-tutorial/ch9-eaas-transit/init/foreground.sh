#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-120 秒"
echo "  (后台会安装 vault / golang-go / jq / curl /"
echo "   postgresql-client；启动 Postgres 容器；"
echo "   启用 transit、创建 payments 密钥；"
echo "   预编译 Gin 应用)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/eaas-app
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version 2>/dev/null | head -1 | awk '{print $2}')，go $(go version 2>/dev/null | awk '{print $3}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (dev 模式 root token)"
echo "✓ transit/ 引擎已启用，密钥 transit/keys/payments 已创建"
echo ""
echo "🐘 Postgres 16 容器：learn-postgres，监听 127.0.0.1:5432"
echo "   用户/口令: postgres / postgres-admin-password；库: payments"
echo "   PG* 环境变量已就绪——直接 \`psql\` 即可连接"
echo ""
echo "📁 Gin 应用源码：/root/eaas-app/app.go"
echo "📁 已预编译的二进制：/root/eaas-app/app"
echo ""
echo "👉 按右侧 step1 开始。"
