#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

start_vault_dev

cd /root
finish_setup
