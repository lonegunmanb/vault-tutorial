#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.1 lab is ready."
echo "Vault server: $VAULT_ADDR"
echo "Unified KV path: secret/seven/app"
echo "Agent config:    /root/agent-config.hcl"
echo "Proxy config:    /root/proxy-config.hcl"
