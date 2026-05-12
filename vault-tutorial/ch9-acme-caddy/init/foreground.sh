#!/bin/bash

echo "================================================="
echo "  正在为你准备实验环境..."
echo "  请稍候，预计需要 60-90 秒"
echo "  (后台会安装 vault / jq / curl / openssl；"
echo "   预拉取 caddy:2.8 镜像；启动 dev 模式 Vault；"
echo "   注册 caddy.local → 127.0.0.1 hosts 解析)"
echo ""
echo "  若长时间停在这一行，请新开一个终端运行："
echo "    tail -f /var/log/acme-init.log"
echo "  即可看到当前卡在哪一步。"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "✅ 环境已就绪！"
echo ""
echo "📦 已安装：vault $(vault version 2>/dev/null | head -1 | awk '{print $2}')，docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
echo "🌐 VAULT_ADDR=$VAULT_ADDR"
echo "🔑 VAULT_TOKEN=$VAULT_TOKEN  (dev 模式 root token)"
echo "🐳 已拉取镜像：$(docker images caddy:2.8 --format '{{.Repository}}:{{.Tag}} ({{.Size}})' 2>/dev/null || echo 'caddy:2.8 (将在 step3 自动拉取)')"
echo "📛 hosts 解析：$(grep caddy.local /etc/hosts)"
echo ""
echo "📁 PKI 工作目录：/root/pki"
echo "📄 一键搭好两级 PKI 的脚本：/root/pki/enable_engines.sh"
echo ""
echo "👉 按右侧 step1 开始。"
