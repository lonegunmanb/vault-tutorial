#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.3 lab is ready."
echo "Vault server: $VAULT_ADDR"
echo "Target KV path: secret/proxy73/app"
echo "Proxy true config:  /root/proxy-config-true.hcl"
echo "Proxy force config: /root/proxy-config-force.hcl"