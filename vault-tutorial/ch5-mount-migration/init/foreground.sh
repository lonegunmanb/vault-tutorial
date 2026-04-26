#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 20-30 秒"
echo "  (后台会自动启动 Vault、写入测试数据、创建用户)"
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
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo ""
echo "当前已挂载的机密引擎："
vault secrets list -format=table | head -10
echo ""
echo "当前已挂载的认证方法："
vault auth list -format=table | head -10
echo ""
echo "已写入的测试数据："
echo "  secret/app-team-a/db, secret/app-team-a/api-key"
echo "  secret/app-team-b/cache"
echo "  legacy-kv/old-service"
echo ""
echo "已创建的测试用户："
echo "  userpass:     alice (policy: app-team-a-read)"
echo "  old-login:    bob   (policy: default)"
echo ""
echo "👉 你现在可以直接执行 vault 命令。"
echo ""
