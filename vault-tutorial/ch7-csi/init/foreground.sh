#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.5 lab is ready."
echo "Kubernetes namespace: csi-demo"
echo "Vault service:        http://vault.vault.svc:8200"
echo "KV path:              secret/csi/app"
echo "File manifest:        /root/csi-file-mount.yaml"
echo "Env sync manifest:    /root/csi-env-sync.yaml"