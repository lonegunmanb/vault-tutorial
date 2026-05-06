#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Vault config-overview lab is ready."
echo "Config file: /root/vault.hcl"
echo "Vault server is NOT yet started. You will start it in step 2."
