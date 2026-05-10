#!/bin/bash
set -euo pipefail

export VAULT_TOKEN="${VAULT_TOKEN:-root}"

kubectl -n vault get pod vault-0 > /dev/null
kubectl -n demo get serviceaccount webapp > /dev/null
kubectl -n vault get serviceaccount vault-agent-injector-init > /dev/null

WEBAPP_TEST_JWT=$(kubectl -n demo create token webapp --duration=10m)

decode_jwt_issuer() {
  local payload
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr -- '-_' '+/')
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.iss // empty'
}

K8S_ISSUER=$(decode_jwt_issuer "$WEBAPP_TEST_JWT")
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

kubectl -n vault delete job vault-agent-injector-init --ignore-not-found=true > /dev/null
cat > /tmp/vault-agent-injector-init-job.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-agent-injector-init
  namespace: vault
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: vault-agent-injector-init
    spec:
      restartPolicy: Never
      serviceAccountName: vault-agent-injector-init
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
            - name: WEBAPP_TEST_JWT
              value: "${WEBAPP_TEST_JWT}"
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
                vault kv put secret/injector/web \
                  username="injector-demo" \
                  password="initial-password" > /dev/null

                printf '%s\n' \
                  'path "secret/data/injector/web" {' \
                  '  capabilities = ["read"]' \
                  '}' \
                  | vault policy write webapp - > /dev/null

                vault write auth/kubernetes/role/webapp \
                  bound_service_account_names="webapp" \
                  bound_service_account_namespaces="demo" \
                  token_policies="webapp" \
                  token_ttl="24h" > /dev/null

                vault read auth/kubernetes/role/webapp > /dev/null
                vault kv get secret/injector/web > /dev/null
                vault write auth/kubernetes/login role="webapp" jwt="\$WEBAPP_TEST_JWT" > /dev/null
              done
EOF

if ! kubectl apply -f /tmp/vault-agent-injector-init-job.yaml > /dev/null; then
  echo "Failed to create Vault initialization job. Manifest follows:" >&2
  sed -n '1,220p' /tmp/vault-agent-injector-init-job.yaml >&2
  exit 1
fi

if ! kubectl -n vault wait --for=condition=complete job/vault-agent-injector-init --timeout=240s > /tmp/vault-agent-injector-init.log 2>&1; then
  echo "Vault initialization job did not complete." >&2
  echo "--- kubectl wait output ---" >&2
  cat /tmp/vault-agent-injector-init.log >&2 || true
  echo "--- job describe ---" >&2
  kubectl -n vault describe job vault-agent-injector-init >&2 || true
  echo "--- init pod status ---" >&2
  kubectl -n vault get pods -l app=vault-agent-injector-init -o wide >&2 || true
  echo "--- init pod events ---" >&2
  INIT_POD=$(kubectl -n vault get pod -l app=vault-agent-injector-init -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$INIT_POD" ]; then
    kubectl -n vault describe pod "$INIT_POD" | sed -n '/Events:/,$p' >&2 || true
  fi
  echo "--- init job logs ---" >&2
  kubectl -n vault logs job/vault-agent-injector-init --tail=120 >&2 || true
  exit 1
fi

echo "Vault Agent Injector lab Vault configuration completed."