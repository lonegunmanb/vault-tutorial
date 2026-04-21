#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 15-30 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/workspace

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo "📦 已安装：tcpdump $(tcpdump --version 2>&1 | head -1)"
echo "📁 工作目录：/root/workspace"
echo ""
echo "⚠️  注意：本实验 Vault 尚未启动，你将在第一步亲手启动 Dev 模式服务器。"
echo ""
