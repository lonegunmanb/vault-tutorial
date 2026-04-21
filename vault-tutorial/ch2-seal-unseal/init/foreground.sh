#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 30-45 秒"
echo "  (后台会自动启动 Vault、init、解封、写入两条机密)"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/workspace
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="$(cat /root/workspace/root.token)"

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo "📁 工作目录：/root/workspace"
echo "📁 5 份分片：/root/workspace/shares/share-{1..5}.key"
echo "📁 初始 Root Token：/root/workspace/root.token"
echo ""
echo "Vault 当前状态："
vault status | grep -E "Initialized|Sealed|Total Shares|Threshold"
echo ""
echo "已写入的机密："
vault kv list secret/
echo ""
echo "👉 你现在可以直接执行 vault 命令，所有环境变量已设置好。"
echo ""
