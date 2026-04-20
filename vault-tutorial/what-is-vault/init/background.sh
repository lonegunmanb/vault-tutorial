#!/bin/bash
# Background setup — runs before the user sees the terminal.
# This scenario teaches a production-style deployment, so we DO NOT pre-start
# vault dev mode. We only install the binary and prepare directories;
# the learner runs `vault server` themselves.

source /root/setup-common.sh

install_vault

# Ensure jq is available (used in step 3 to parse vault init JSON output)
if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Prepare production-style directory layout
mkdir -p /etc/vault.d
mkdir -p /opt/vault/data

# Create a dedicated workspace for the learner
mkdir -p /root/workspace
cd /root/workspace

finish_setup
