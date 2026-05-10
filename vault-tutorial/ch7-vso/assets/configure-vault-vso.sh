#!/bin/bash
set -euo pipefail

export VAULT_TOKEN="${VAULT_TOKEN:-root}"

kubectl -n vault get pod vault-0 > /dev/null
kubectl -n vso-demo get serviceaccount vso-app > /dev/null
kubectl -n vault get serviceaccount vault-vso-init > /dev/null

VSO_TEST_JWT=$(kubectl -n vso-demo create token vso-app --audience=vault --duration=10m)

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
if [ -z "$K8S_ISSUER" ]; then
  echo "Kubernetes ServiceAccount issuer was not detected" >&2
  exit 1
fi
echo "Kubernetes ServiceAccount issuer: $K8S_ISSUER"

VAULT_TARGETS=$(kubectl -n vault get pods \
  -l app.kubernetes.io/name=vault,component=server \
  -o jsonpath='{range .items[*]}{.metadata.name}{".vault-internal.vault.svc.cluster.local "}{end}' 2>/dev/null || true)
if [ -z "$VAULT_TARGETS" ]; then
  VAULT_TARGETS="vault-0.vault-internal.vault.svc.cluster.local"
fi
VAULT_JOB_IMAGE=$(kubectl -n vault get pod vault-0 \
  -o jsonpath='{.spec.containers[?(@.name=="vault")].image}' 2>/dev/null || true)
VAULT_JOB_IMAGE="${VAULT_JOB_IMAGE:-hashicorp/vault:1.21.2}"

kubectl -n vault delete job vault-vso-init --ignore-not-found=true > /dev/null
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
                vault write auth/kubernetes/login role="vso-app" jwt="\$VSO_TEST_JWT" > /dev/null
              done
EOF

if ! kubectl apply -f /tmp/vault-vso-init-job.yaml > /dev/null; then
  echo "Failed to create Vault VSO initialization job. Manifest follows:" >&2
  sed -n '1,240p' /tmp/vault-vso-init-job.yaml >&2
  exit 1
fi

if ! kubectl -n vault wait --for=condition=complete job/vault-vso-init --timeout=240s > /tmp/vault-vso-init.log 2>&1; then
  echo "Vault VSO initialization job did not complete." >&2
  echo "--- kubectl wait output ---" >&2
  cat /tmp/vault-vso-init.log >&2 || true
  echo "--- job describe ---" >&2
  kubectl -n vault describe job vault-vso-init >&2 || true
  echo "--- init pod status ---" >&2
  kubectl -n vault get pods -l app=vault-vso-init -o wide >&2 || true
  echo "--- init pod events ---" >&2
  INIT_POD=$(kubectl -n vault get pod -l app=vault-vso-init -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$INIT_POD" ]; then
    kubectl -n vault describe pod "$INIT_POD" | sed -n '/Events:/,$p' >&2 || true
  fi
  echo "--- init job logs ---" >&2
  kubectl -n vault logs job/vault-vso-init --tail=120 >&2 || true
  exit 1
fi

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

echo "Vault VSO lab Vault configuration and manifests completed."