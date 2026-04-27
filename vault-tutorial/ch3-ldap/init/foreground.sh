#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会自动安装 Vault、启动 OpenLDAP 容器、预置账号)"
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
echo "📁 OpenLDAP 已启动："
echo "   地址 : ldap://127.0.0.1:389"
echo "   Admin: cn=admin,dc=example,dc=org / admin"
echo ""
echo "📂 预置目录结构："
echo "   ou=ServiceAccounts (app1/2/3, svc-ops-1/2/3)"
echo "   ou=DynamicUsers    (空，待 step3 现场创建)"
echo ""
echo "🔧 工具：vault / ldapsearch / ldapadd / ldapmodify / jq / docker"
echo ""
echo "👉 按右侧 step1 开始。"
