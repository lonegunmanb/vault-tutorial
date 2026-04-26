#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 20-30 秒"
echo "  (后台会自动安装并以 Dev 模式启动 Vault)"
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
echo "Vault 已以 Dev 模式启动 (root token = root)。"
echo "本实验从一个干净的 Vault 开始——除内置 secret/、cubbyhole/、sys/、"
echo "identity/ 之外，没有任何业务挂载点。"
echo ""
echo "当前已挂载的机密引擎："
vault secrets list -format=table
echo ""
echo "👉 你现在可以直接执行 vault 命令。"
echo ""
