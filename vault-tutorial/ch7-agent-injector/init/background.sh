#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!
apt-get update -qq && apt-get install -y -qq jq curl tar gzip ca-certificates > /dev/null 2>&1

if [ -z "${KUBECONFIG:-}" ]; then
  if [ -f /root/.kube/config ]; then
    export KUBECONFIG=/root/.kube/config
  elif [ -f /etc/kubernetes/admin.conf ]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

cat > /etc/profile.d/kubernetes.sh <<EOF
export KUBECONFIG='${KUBECONFIG:-/root/.kube/config}'
EOF
chmod +x /etc/profile.d/kubernetes.sh
grep -q "KUBECONFIG=" /root/.bashrc 2>/dev/null || cat /etc/profile.d/kubernetes.sh >> /root/.bashrc

echo "Waiting for Kubernetes to be ready..."
for i in $(seq 1 180); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    echo "Kubernetes ready."
    break
  fi
  sleep 1
done

if ! command -v helm > /dev/null 2>&1; then
  HELM_VERSION="v3.15.4"
  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || cat /etc/profile.d/vault.sh >> /root/.bashrc

cat > /usr/local/bin/ensure-vault-port-forward <<'EOF'
#!/bin/bash
set +e

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

pkill -f "kubectl -n vault port-forward svc/vault 8200:8200" > /dev/null 2>&1 || true
nohup kubectl -n vault port-forward svc/vault 8200:8200 > /tmp/vault-port-forward.log 2>&1 < /dev/null &

for attempt in $(seq 1 45); do
  if vault status > /dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done

echo "Vault port-forward is not ready. Recent log:" >&2
tail -20 /tmp/vault-port-forward.log >&2 2>/dev/null || true
exit 1
EOF
chmod +x /usr/local/bin/ensure-vault-port-forward

cat > /root/baseline.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: baseline
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: baseline
  template:
    metadata:
      labels:
        app: baseline
    spec:
      serviceAccountName: webapp
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
EOF

cat > /root/injector-demo.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: injector-demo
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: injector-demo
  template:
    metadata:
      labels:
        app: injector-demo
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/service: "http://vault.vault.svc:8200"
        vault.hashicorp.com/role: "webapp"
        vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/injector/web"
        vault.hashicorp.com/agent-inject-template-config.txt: |
          {{- with secret "secret/data/injector/web" -}}
          username={{ .Data.data.username }}
          password={{ .Data.data.password }}
          {{- end }}
        vault.hashicorp.com/agent-inject-perms-config.txt: "0400"
        vault.hashicorp.com/template-static-secret-render-interval: "10s"
    spec:
      serviceAccountName: webapp
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
EOF

cat > /root/init-only-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: injector-init-only
  namespace: demo
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: injector-init-only
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/service: "http://vault.vault.svc:8200"
        vault.hashicorp.com/role: "webapp"
        vault.hashicorp.com/agent-pre-populate-only: "true"
        vault.hashicorp.com/agent-inject-secret-config.txt: "secret/data/injector/web"
        vault.hashicorp.com/agent-inject-template-config.txt: |
          {{- with secret "secret/data/injector/web" -}}
          username={{ .Data.data.username }}
          password={{ .Data.data.password }}
          {{- end }}
    spec:
      restartPolicy: Never
      serviceAccountName: webapp
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sh", "-c", "cat /vault/secrets/config.txt && echo job-finished"]
EOF

wait "$INSTALL_VAULT_PID"

cd /root
finish_setup