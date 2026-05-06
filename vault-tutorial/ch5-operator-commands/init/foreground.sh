#!/bin/bash

echo "================================================="
echo "  正在准备 operator 命令实验环境..."
echo "  请稍候，预计需要 20-30 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root/operator-lab
clear

echo "环境已就绪。"
echo ""
echo "已安装：vault $(vault version | head -1 | awk '{print $2}')"
echo "实验目录：/root/operator-lab"
echo ""
echo "已准备的文件："
ls -1 *.hcl *.sh 2>/dev/null
echo ""
echo "本实验不会自动启动 Vault。你将在步骤中亲手启动本地 Vault 与 Raft 小集群。"
echo ""