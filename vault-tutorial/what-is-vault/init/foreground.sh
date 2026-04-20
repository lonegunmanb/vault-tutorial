#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 15-30 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

# Set VAULT_ADDR for production-style HTTPS-less local lab
export VAULT_ADDR='http://127.0.0.1:8200'
echo "export VAULT_ADDR='http://127.0.0.1:8200'" >> /root/.bashrc

cd /root/workspace

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo "📁 工作目录：/root/workspace"
echo "📁 配置目录：/etc/vault.d"
echo "📁 数据目录：/opt/vault/data"
echo ""
echo "👉 注意：本实验不使用 dev 模式。你将亲手启动一个生产风格的 Vault。"
echo ""
