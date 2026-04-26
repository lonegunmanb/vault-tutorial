#!/bin/bash
source /root/setup-common.sh

# 并行执行：install_vault（下载 ~70MB zip + 装 unzip）和 apt 装 jq
# 串行起来要做两次 apt-get update，非常慢；放后台并行即可省掉一半时间。
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# 等 vault 二进制就位后再启动 dev server
wait "$INSTALL_VAULT_PID"

# start_vault_dev already waits internally for the server to be healthy.
start_vault_dev

# 本实验的所有 enable / disable / tune / 数据写入都由学员手动完成。
# 这里不再预置任何业务挂载点，避免干扰学员对"全新挂载点"的观察。

cd /root
finish_setup
