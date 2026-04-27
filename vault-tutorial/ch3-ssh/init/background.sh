#!/bin/bash
source /root/setup-common.sh

# 并行：装 vault + 装 jq/sshpass + 预拉 ubuntu 镜像
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1 || ! command -v sshpass > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq sshpass openssh-client > /dev/null 2>&1
fi

# Killercoda 的 ubuntu 镜像通常已带 docker；如果没有就装
if ! command -v docker > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq docker.io > /dev/null 2>&1
fi

# 预热拉取目标主机镜像，让 step2 启动容器时秒级响应
docker pull ubuntu:24.04 > /dev/null 2>&1 &
PULL_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$PULL_PID" 2>/dev/null

start_vault_dev

# 为客户端预先生成一对 SSH 密钥（无密码），后续 step 直接签它的公钥
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -C "vault-ssh-lab" > /dev/null 2>&1
fi

cd /root
finish_setup
