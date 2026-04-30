#!/bin/bash
source /root/setup-common.sh

# 并行：装 vault + 装 oathtool/jq
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v oathtool > /dev/null 2>&1 \
   || ! command -v jq > /dev/null 2>&1 \
   || ! command -v base64 > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq oathtool jq coreutils > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

start_vault_dev

# 不预置任何 TOTP key——所有写入与读 code 都由学员手动执行，
# 才能看到引擎从空白状态一步步建立的全过程。

cd /root
finish_setup
