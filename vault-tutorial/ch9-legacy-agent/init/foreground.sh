#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 90-150 秒"
echo "  (后台会安装 Vault、Consul-Template、PostgreSQL 客户端、Docker，"
echo "   启动 Vault dev server 与 PostgreSQL 容器，配置 database 机密引擎，"
echo "   安装模拟遗留应用的可执行文件，并生成 Consul-Template 与 Vault Agent 配置文件)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/legacy-lab
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version 2>/dev/null | head -1 | awk '{print $2}')，consul-template $(consul-template -v 2>&1 | head -1 | awk '{print $3}')，psql $(psql --version | awk '{print $3}')"
echo "🌐 Vault：$VAULT_ADDR  (root token=root)"
echo "🐘 PostgreSQL：127.0.0.1:5432  (root / rootpassword)"
echo "📁 工作目录：/root/legacy-lab"
echo "🧱 模拟旧应用：/usr/local/bin/legacy-app"
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。"
