#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.5 lab is ready."
echo "Start with Step 1 to install CSI driver, Vault, and the Vault provider."
echo "Kubernetes namespace: csi-demo"
echo "Vault service:        http://vault.vault.svc:8200"
echo "KV path:              secret/csi/app"
echo "Step 1 generates:     /root/csi-file-mount.yaml and /root/csi-env-sync.yaml"