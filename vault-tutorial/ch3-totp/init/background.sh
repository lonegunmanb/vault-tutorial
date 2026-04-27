#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq oathtool qrencode jq > /dev/null 2>&1

wait "$INSTALL_VAULT_PID"

start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 启用 totp/ 引擎
vault secrets enable totp 2>/dev/null

cd /root
finish_setup
