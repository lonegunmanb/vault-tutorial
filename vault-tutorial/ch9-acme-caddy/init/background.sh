#!/bin/bash
set +e

# ─── 全量日志 ──────────────────────────────────────────────
LOG=/var/log/acme-init.log
exec > >(tee -a "$LOG") 2>&1
export PS4='+ [\D{%H:%M:%S}] '
set -x

stage() { echo "===== [$(date +%H:%M:%S)] $* ====="; }

stage "background.sh start"

if [ ! -f /root/setup-common.sh ]; then
  echo "FATAL: /root/setup-common.sh missing — assets were not copied. Aborting."
  exit 1
fi
source /root/setup-common.sh
type install_vault finish_setup start_vault_dev || {
  echo "FATAL: setup-common.sh did not define expected helpers"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

stage "apt-get update"
apt-get update -qq
stage "apt-get install unzip jq curl openssl"
apt-get install -y -qq unzip jq curl openssl

stage "install_vault"
install_vault

# Caddy 镜像预拉取（70MB），避免 step3 启动 Caddy 时学员等待网络。
# 如果 Killercoda 的 docker 仓库未代理 docker.io，pull 失败也允许实验继续，
# Caddy 容器在 step3 里 docker run 时会再次尝试拉取。
stage "docker pull caddy:2.8"
docker pull caddy:2.8 || echo "WARN: docker pull caddy:2.8 failed; will retry in step3"

stage "start_vault_dev"
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 把 caddy.local 写到 /etc/hosts，让 Vault（host 进程）与 curl（host 进程）
# 都能解析这个名字到 127.0.0.1。Caddy 容器走 --network host，本机的
# /etc/hosts 也会被它直接看到。
stage "register caddy.local in /etc/hosts"
grep -q 'caddy.local' /etc/hosts || echo '127.0.0.1 caddy.local' >> /etc/hosts

# 提前建好 /root/pki 目录，避免 enable_engines.sh 第一次执行时找不到工作目录。
mkdir -p /root/pki

stage "finish_setup"
finish_setup
stage "background.sh DONE"
