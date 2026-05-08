#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1

if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f /root/.kube/config ]; then
    export KUBECONFIG=/root/.kube/config
  elif [ -f /etc/kubernetes/admin.conf ]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

echo "Waiting for Kubernetes to be ready..."
for i in $(seq 1 120); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    echo "Kubernetes ready."
    break
  fi
  sleep 1
done

if ! kubectl create token --help > /dev/null 2>&1; then
  echo "WARNING: kubectl create token is unavailable; this scenario requires TokenRequest support."
fi

if [ ! -f /etc/kubernetes/pki/sa.pub ]; then
  echo "WARNING: /etc/kubernetes/pki/sa.pub was not found; JWT public-key configuration may fail."
fi

cat > /etc/profile.d/kubernetes.sh <<EOF
export KUBECONFIG='${KUBECONFIG:-/root/.kube/config}'
EOF
chmod +x /etc/profile.d/kubernetes.sh
grep -q "KUBECONFIG=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/kubernetes.sh >> /root/.bashrc

wait "$INSTALL_VAULT_PID"
start_vault_dev

cd /root
finish_setup