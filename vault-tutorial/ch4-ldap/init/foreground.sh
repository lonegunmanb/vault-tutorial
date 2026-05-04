#!/bin/bash

echo "================================================="
echo "  正在准备 LDAP 认证实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会安装 Vault、启动 OpenLDAP、预置用户与组)"
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
echo "📦 Vault: $(vault version 2>/dev/null | head -1 | awk '{print $2}')"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN"
echo ""
echo "📁 OpenLDAP 已启动："
echo "   地址 : ldap://127.0.0.1:389"
echo "   Admin: cn=admin,dc=example,dc=org / admin"
echo "   Base : dc=example,dc=org"
echo ""
echo "👥 预置用户："
echo "   alice / alice-pass  -> dev + ops"
echo "   bob   / bob-pass    -> dev"
echo "   carol / carol-pass  -> contractors, employeeType=Contractor"
echo "   (Vault binddn 直接使用 cn=admin / admin，简化 ACL 配置)"
echo ""
echo "🔧 工具：vault / ldapsearch / ldapwhoami / ldapadd / jq / docker"
echo ""
echo "👉 按右侧 step1 开始。"