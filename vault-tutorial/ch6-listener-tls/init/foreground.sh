#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Vault listener-tls lab is ready."
echo "Config file: /root/vault.hcl  (currently TLS-disabled HTTP)"
echo "TLS cert directory: /etc/vault.d/tls (currently empty)"
echo "Vault server is NOT yet started. You will start it in step 1."
