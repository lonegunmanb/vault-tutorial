#!/bin/bash
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

cd /root
clear
echo "Chapter 7.6 lab is ready."
echo "Start with Step 1 to install Vault and Vault Secrets Operator."
echo "Kubernetes namespace:           vso-demo"
echo "Vault service:                  http://vault.vault.svc:8200"
echo "Vault KV path (kv-v2):          secret/vso/app"
echo "VSO namespace:                  vault-secrets-operator"
echo "Manifests:"
echo "  /root/vso-conn-auth.yaml"
echo "  /root/vso-static-secret.yaml"
echo "  /root/vso-app-deployment.yaml"
echo "  /root/vso-static-secret-rollout.yaml"
