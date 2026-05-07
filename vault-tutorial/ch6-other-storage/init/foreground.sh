#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "其他存储后端实验环境准备就绪。"
echo ""
echo "五份预置的 vault.hcl："
echo "  /root/vault-file.hcl       — storage \"file\" { path = /opt/vault/file-data }"
echo "  /root/vault-inmem.hcl      — storage \"inmem\" {}"
echo "  /root/vault-pg.hcl         — storage \"postgresql\" { connection_url = ... }"
echo "  /root/vault-s3.hcl         — storage \"s3\" { endpoint = ministack:4566 }"
echo "  /root/vault-dynamodb.hcl   — storage \"dynamodb\" { endpoint = ministack:4566 }"
echo ""
echo "便捷脚本："
echo "  ./start-vault.sh <file|inmem|pg|s3|dynamodb>   # 切换并重启 Vault"
echo "  ./start-postgres.sh                            # Step3 才需要"
echo "  ./start-ministack.sh                           # Step4 / Step5 才需要"
echo ""
echo "VAULT_ADDR 默认 = http://127.0.0.1:8200"
echo "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY = test/test（已持久化，指向 ministack）"
echo ""
echo "Vault 进程目前未启动；请按步骤逐一拉起。"
