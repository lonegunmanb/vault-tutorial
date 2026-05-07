#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "其他存储后端实验环境准备就绪。"
echo ""
echo "三份预置的 vault.hcl："
echo "  /root/vault-file.hcl   — storage \"file\" { path = /opt/vault/file-data }"
echo "  /root/vault-inmem.hcl  — storage \"inmem\" {}"
echo "  /root/vault-pg.hcl     — storage \"postgresql\" { connection_url = ... }"
echo ""
echo "便捷脚本："
echo "  ./start-vault.sh <file|inmem|pg>   # 切换并重启 Vault"
echo "  ./start-postgres.sh                # Step3 才需要：拉起一个本地 postgres"
echo ""
echo "VAULT_ADDR 默认 = http://127.0.0.1:8200"
echo ""
echo "Vault 进程目前未启动；请按步骤逐一拉起。"
