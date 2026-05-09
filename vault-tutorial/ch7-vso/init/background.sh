#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq curl jq ca-certificates > /dev/null 2>&1

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
grep -q "KUBECONFIG=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/kubernetes.sh >> /root/.bashrc

echo "Waiting for Kubernetes to be ready..."
for i in $(seq 1 150); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    echo "Kubernetes ready."
    break
  fi
  sleep 1
done

if ! command -v helm > /dev/null 2>&1; then
  echo "Installing Helm..."
  curl --connect-timeout 10 --max-time 120 -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh > /dev/null 2>&1
fi

helm repo add hashicorp https://helm.releases.hashicorp.com > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1

echo "Installing Vault dev server..."
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "csi.enabled=false" \
  --set "injector.enabled=false" \
  > /tmp/helm-vault.log 2>&1

kubectl -n vault rollout status statefulset/vault --timeout=180s > /tmp/vault-rollout.log 2>&1 || true

echo "Waiting for Vault pod..."
for i in $(seq 1 120); do
  if kubectl -n vault get pod vault-0 2>/dev/null | grep -q "Running"; then
    break
  fi
  sleep 1
done

# Allow Vault SA to call Kubernetes TokenReview API for the Kubernetes auth method.
kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

echo "Creating vso-demo namespace and ServiceAccount..."
kubectl create namespace vso-demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n vso-demo create serviceaccount vso-app --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

echo "Configuring Vault Kubernetes auth, KV data and policy..."
kubectl -n vault exec vault-0 -- /bin/sh -c '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

# KV v2 is enabled at secret/ by default in dev mode.
vault kv put secret/vso/app \
  username="vso-user" \
  password="initial-password" > /dev/null

vault policy write vso-app - > /dev/null <<EOF
path "secret/data/vso/app" {
  capabilities = ["read"]
}
EOF

vault auth enable kubernetes > /dev/null 2>&1 || true
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  > /dev/null

vault write auth/kubernetes/role/vso-app \
  bound_service_account_names="vso-app" \
  bound_service_account_namespaces="vso-demo" \
  token_policies="vso-app" \
  token_ttl="20m" \
  audience="vault" \
  > /dev/null
'

echo "Installing Vault Secrets Operator..."
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator \
  --create-namespace \
  --version 0.10.0 \
  > /tmp/helm-vso.log 2>&1

kubectl -n vault-secrets-operator rollout status deployment/vault-secrets-operator-controller-manager --timeout=240s \
  > /tmp/vso-rollout.log 2>&1 || true

# Pre-write manifests the learner will apply.
cat > /root/vso-conn-auth.yaml <<'EOF'
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: vso-demo
spec:
  address: http://vault.vault.svc.cluster.local:8200
  skipTLSVerify: false
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: vso-demo
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: vso-app
    serviceAccount: vso-app
    audiences:
      - vault
EOF

cat > /root/vso-static-secret.yaml <<'EOF'
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vso-app-static
  namespace: vso-demo
spec:
  vaultAuthRef: vault-auth
  mount: secret
  type: kv-v2
  path: vso/app
  refreshAfter: 15s
  destination:
    create: true
    name: vso-app-secret
EOF

cat > /root/vso-app-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vso-app
  namespace: vso-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vso-app
  template:
    metadata:
      labels:
        app: vso-app
    spec:
      serviceAccountName: vso-app
      containers:
        - name: app
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              echo "starting; current credentials:"
              env | grep '^APP_' || true
              while true; do sleep 3600; done
          envFrom:
            - secretRef:
                name: vso-app-secret
                optional: false
          env:
            - name: APP_USERNAME
              valueFrom:
                secretKeyRef:
                  name: vso-app-secret
                  key: username
            - name: APP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: vso-app-secret
                  key: password
EOF

cat > /root/vso-static-secret-rollout.yaml <<'EOF'
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vso-app-static
  namespace: vso-demo
spec:
  vaultAuthRef: vault-auth
  mount: secret
  type: kv-v2
  path: vso/app
  refreshAfter: 15s
  destination:
    create: true
    name: vso-app-secret
  rolloutRestartTargets:
    - kind: Deployment
      name: vso-app
EOF

wait "$INSTALL_VAULT_PID" 2>/dev/null

cd /root
touch /tmp/.setup-done
