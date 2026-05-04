#!/bin/bash
set +e

source /root/setup-common.sh

apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1
install_vault
start_vault_dev

cd /root
finish_setup