#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.2 lab is ready."
echo "Vault server:       $VAULT_ADDR"
echo "KV path:            secret/agent/app"
echo "File Agent config:  /root/agent-file.hcl"
echo "Supervisor config:  /root/agent-supervisor.hcl"