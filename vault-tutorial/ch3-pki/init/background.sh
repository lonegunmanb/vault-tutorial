#!/bin/bash
set +e

source /root/setup-common.sh

# ─────────────────────────────────────────────────────────
# 装 Vault + 安装 openssl/jq（openssl 通常已自带，确保一下）
# ─────────────────────────────────────────────────────────
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq openssl curl > /dev/null 2>&1

wait "$INSTALL_VAULT_PID"

# ─────────────────────────────────────────────────────────
# 启动 Vault Dev
# ─────────────────────────────────────────────────────────
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# ─────────────────────────────────────────────────────────
# 工作目录：所有 CSR / PEM / chain 放这里
# ─────────────────────────────────────────────────────────
mkdir -p /root/pki-lab
cd /root/pki-lab

# 不预置任何 pki/ mount —— 学员在 step1 自己启用
finish_setup
