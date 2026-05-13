#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-60 秒"
echo "  (后台会安装 vault / ldap-utils / jq；"
echo "   启动一台 osixia/openldap:1.5.0 容器；"
echo "   预先创建用户 alice 并写入初始口令 1LearnedVault；"
echo "   启动 dev 模式 Vault)"
echo ""
echo "  若长时间停在这一行，请新开一个终端运行："
echo "    tail -f /var/log/ldap-rotation-init.log"
echo "  即可看到当前卡在哪一步。"
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
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (dev 模式 root token)"
echo ""
echo "📁 OpenLDAP 已启动："
echo "   地址  : ldap://127.0.0.1:389"
echo "   Admin : cn=admin,dc=learn,dc=example / 2LearnVault"
echo "   用户  : cn=alice,ou=users,dc=learn,dc=example / 1LearnedVault"
echo ""
echo "🔧 工具：vault / ldapsearch / ldapadd / jq / docker"
echo ""
echo "👉 按右侧 step1 开始。"
