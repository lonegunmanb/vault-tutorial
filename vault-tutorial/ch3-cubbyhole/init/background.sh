#!/bin/bash
source /root/setup-common.sh

# 并行：装 vault + 装 jq
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

start_vault_dev

# 本实验所有 cubbyhole 写入、token 创建、wrap/unwrap 都由学员手动执行。
# 不预置任何数据，避免污染对"Token 隔离"的观察。

cd /root
finish_setup
