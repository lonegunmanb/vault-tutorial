#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-45 秒"
echo "  (后台会自动安装 Vault、Docker，预拉 ubuntu 镜像)"
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
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')，docker，jq，sshpass"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (Dev 模式 root token)"
echo "🔐 客户端密钥：/root/.ssh/id_rsa (无密码)"
echo ""
echo "👉 接下来按照右侧实验步骤操作即可。"
