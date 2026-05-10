#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.4 lab is ready."
echo "Vault address:     ${VAULT_ADDR:-http://127.0.0.1:8200}"
echo "Kubernetes ns:     demo"
echo "Annotated deploy:  /root/injector-demo.yaml"
echo "Init-only job:     /root/init-only-job.yaml"
echo "Vault reconnect:   ensure-vault-port-forward"