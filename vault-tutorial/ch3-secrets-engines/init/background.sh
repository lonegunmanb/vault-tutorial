#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Start Vault in dev mode (root token = root, in-memory storage).
# start_vault_dev already waits internally for the server to be healthy.
start_vault_dev

# 本实验的所有 enable / disable / tune / 数据写入都由学员手动完成。
# 这里不再预置任何业务挂载点，避免干扰学员对"全新挂载点"的观察。

cd /root
finish_setup
