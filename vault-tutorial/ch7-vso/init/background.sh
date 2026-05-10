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

echo "Creating vso-demo namespace and ServiceAccount..."
kubectl create namespace vso-demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n vso-demo create serviceaccount vso-app --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"
kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n vault create serviceaccount vault-vso-init --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

VSO_TEST_JWT=$(kubectl -n vso-demo create token vso-app --audience=vault --duration=10m 2>/dev/null)
decode_jwt_issuer() {
  local payload
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr -- '-_' '+/')
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.iss // empty'
}
K8S_ISSUER=$(decode_jwt_issuer "$VSO_TEST_JWT")
if [ -z "$K8S_ISSUER" ]; then
  K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | jq -r '.issuer // empty')
fi
echo "Kubernetes ServiceAccount issuer: ${K8S_ISSUER:-unknown}"

VAULT_TARGETS=$(kubectl -n vault get pods \
  -l app.kubernetes.io/name=vault,component=server \
  -o jsonpath='{range .items[*]}{.metadata.name}{".vault-internal.vault.svc.cluster.local "}{end}' 2>/dev/null)
if [ -z "$VAULT_TARGETS" ]; then
  VAULT_TARGETS="vault-0.vault-internal.vault.svc.cluster.local"
fi
VAULT_JOB_IMAGE=$(kubectl -n vault get pod vault-0 \
  -o jsonpath='{.spec.containers[?(@.name=="vault")].image}' 2>/dev/null)
VAULT_JOB_IMAGE="${VAULT_JOB_IMAGE:-hashicorp/vault:1.21.2}"

echo "Configuring Vault Kubernetes auth, KV data and policy..."
kubectl -n vault delete job vault-vso-init --ignore-not-found=true > /dev/null 2>&1
cat > /tmp/vault-vso-init-job.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-vso-init
  namespace: vault
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: vault-vso-init
    spec:
      restartPolicy: Never
      serviceAccountName: vault-vso-init
      automountServiceAccountToken: false
      containers:
        - name: init
          image: ${VAULT_JOB_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: VAULT_TOKEN
              value: root
            - name: K8S_ISSUER
              value: "${K8S_ISSUER}"
            - name: VAULT_TARGETS
              value: "${VAULT_TARGETS}"
            - name: VSO_TEST_JWT
              value: "${VSO_TEST_JWT}"
          command:
            - /bin/sh
            - -ec
          args:
            - |
              for target in \$VAULT_TARGETS; do
                export VAULT_ADDR="http://\${target}:8200"
                echo "Initializing \${VAULT_ADDR}"

                if [ -z "\$K8S_ISSUER" ]; then
                  echo "Kubernetes ServiceAccount issuer was not detected" >&2
                  exit 1
                fi

                ready=false
                for attempt in \$(seq 1 60); do
                  if vault status > /dev/null 2>&1; then
                    ready=true
                    break
                  fi
                  sleep 2
                done
                if [ "\$ready" != "true" ]; then
                  echo "Vault target did not become ready: \${VAULT_ADDR}" >&2
                  exit 1
                fi

                vault auth enable kubernetes > /dev/null 2>&1 || true
                vault write auth/kubernetes/config \
                  kubernetes_host="https://kubernetes.default.svc:443" \
                  issuer="\$K8S_ISSUER" > /dev/null

                vault secrets enable -path=secret kv-v2 > /dev/null 2>&1 || true
                vault kv put secret/vso/app \
                  username="vso-user" \
                  password="initial-password" > /dev/null

                printf '%s\n' \
                  'path "secret/data/vso/app" {' \
                  '  capabilities = ["read"]' \
                  '}' \
                  | vault policy write vso-app - > /dev/null

                vault write auth/kubernetes/role/vso-app \
                  bound_service_account_names="vso-app" \
                  bound_service_account_namespaces="vso-demo" \
                  token_policies="vso-app" \
                  token_ttl="20m" \
                  audience="vault" > /dev/null

                vault read auth/kubernetes/role/vso-app > /dev/null
                vault kv get secret/vso/app > /dev/null
                if [ -n "\$VSO_TEST_JWT" ]; then
                  vault write auth/kubernetes/login role="vso-app" jwt="\$VSO_TEST_JWT" > /dev/null
                fi
              done
EOF

if ! kubectl apply -f /tmp/vault-vso-init-job.yaml > /dev/null; then
  echo "WARNING: Failed to create Vault VSO initialization job. Manifest follows:"
  sed -n '1,240p' /tmp/vault-vso-init-job.yaml
elif ! kubectl -n vault wait --for=condition=complete job/vault-vso-init --timeout=240s > /tmp/vault-vso-init.log 2>&1; then
  echo "WARNING: Vault VSO initialization job did not complete. Recent logs:"
  echo "--- kubectl wait output ---"
  cat /tmp/vault-vso-init.log || true
  echo "--- job describe ---"
  kubectl -n vault describe job vault-vso-init || true
  echo "--- init pod status ---"
  kubectl -n vault get pods -l app=vault-vso-init -o wide || true
  echo "--- init pod events ---"
  INIT_POD=$(kubectl -n vault get pod -l app=vault-vso-init -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$INIT_POD" ]; then
    kubectl -n vault describe pod "$INIT_POD" | sed -n '/Events:/,$p' || true
  fi
  echo "--- init job logs ---"
  kubectl -n vault logs job/vault-vso-init --tail=120 || true
else
  echo "Vault VSO initialization job completed."
fi

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
