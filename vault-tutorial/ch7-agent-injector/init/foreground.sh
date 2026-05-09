#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.4 lab is ready."
echo "Vault address:     $VAULT_ADDR"
echo "Kubernetes ns:     demo"
echo "Annotated deploy:  /root/injector-demo.yaml"
echo "Init-only job:     /root/init-only-job.yaml"