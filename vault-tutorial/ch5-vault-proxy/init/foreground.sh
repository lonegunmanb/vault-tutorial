#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Vault Proxy lab is ready."
echo "Vault server: $VAULT_ADDR"
echo "Proxy config: /root/proxy-config.hcl"
