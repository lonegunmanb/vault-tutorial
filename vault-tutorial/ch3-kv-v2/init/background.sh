#!/bin/bash
source /root/setup-common.sh

# 并行：装 vault + 装 jq，省掉一次 apt-get update
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

# start_vault_dev 内部已经等到健康才返回
start_vault_dev

# 本实验所有 enable / 写入 / 删除 / Policy 操作都由学员手动执行。
# 这里不预置任何 KV 数据，避免污染对版本号 / 元数据 / 软删硬删的观察。

cd /root
finish_setup
