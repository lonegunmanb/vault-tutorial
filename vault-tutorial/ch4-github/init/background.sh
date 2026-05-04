#!/bin/bash
set +e

source /root/setup-common.sh

# Step A: install all apt packages serially. Doing this BEFORE the parallel
# downloads avoids dpkg lock contention with install_vault (which also calls
# apt for unzip) and ensures curl exists before install_vault runs.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl unzip jq openssl ca-certificates nginx nodejs npm python3 \
    > /tmp/apt-install.log 2>&1

# Step B: now parallel-install vault + prism (no more apt calls; just downloads).
install_vault &
INSTALL_VAULT_PID=$!

(
  if ! command -v prism > /dev/null 2>&1; then
    # Prism 5.x is broken on Node 18 (faker-js ESM-only). 4.10.5 is the last
    # stable on stock Ubuntu node.
    npm install -g '@stoplight/prism-cli@4.10.5' > /tmp/prism-install.log 2>&1
  fi
) &
INSTALL_PRISM_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_PRISM_PID" 2>/dev/null

start_vault_dev

# Stop nginx if Ubuntu auto-started a default site on :80 — we only want to
# run our own TLS server on :443, on demand from step1.
systemctl stop nginx > /dev/null 2>&1 || true
systemctl disable nginx > /dev/null 2>&1 || true
# In containers without systemd, kill any auto-started nginx just in case.
pkill nginx 2>/dev/null

cd /root
finish_setup
