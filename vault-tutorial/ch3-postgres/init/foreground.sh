#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-90 秒"
echo "  (后台会自动安装 Vault、启动 PostgreSQL 容器、预置账号)"
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
echo "🐘 PostgreSQL 16 容器已启动：127.0.0.1:5432"
echo "   超级用户  : root / rootpassword         (调试 / 验证用)"
echo "   Vault root: vaultadmin / vaultadmin     (CREATEROLE + demo grant option，给 Vault 在 step1 写连接)"
echo "   既有账号  : legacy_app / legacy-pass    (给 step3 onboarding 演示)"
echo "   演示数据  : demo.kv (k,v)，预置 ('hello','world'), ('vault','rocks')"
echo ""
echo "🔧 工具：vault / psql / jq / docker"
echo "   连 PG 例：psql -h 127.0.0.1 -U root -d postgres   (密码: rootpassword)"
echo ""
echo "👉 按右侧 step1 开始。"
