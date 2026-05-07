#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Vault auto-seal lab is ready."
echo "Config file: /root/vault.hcl  (no seal block yet — you will add one in step 2)"
echo "LocalStack container is NOT yet started; you will start it in step 1."
echo "Vault server is NOT yet started; you will start it in step 2."
