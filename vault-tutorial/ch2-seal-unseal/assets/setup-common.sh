#!/bin/bash
# This file is overwritten by `npm run sync-setup` from scripts/setup-common.sh
# Do NOT edit directly. Edit the source file at scripts/setup-common.sh instead.

VAULT_VERSION="${VAULT_VERSION:-1.19.2}"

install_vault() {
  if ! command -v unzip > /dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq unzip > /dev/null 2>&1
  fi

  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" \
    -o /tmp/vault.zip \
    && unzip -o -q /tmp/vault.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/vault \
    && rm -f /tmp/vault.zip

  vault version || echo "WARNING: vault install failed"
}

finish_setup() {
  touch /tmp/.setup-done
}
