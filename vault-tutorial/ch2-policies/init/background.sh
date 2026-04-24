#!/bin/bash
# Background setup — runs before the user sees the terminal.

source /root/setup-common.sh

install_vault
start_vault_dev
start_postgres

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

finish_setup
