#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq curl tar gzip > /dev/null 2>&1

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

helm repo add hashicorp https://helm.releases.hashicorp.com > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1 || true

helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set='server.dev.enabled=true' \
  --set='server.dev.devRootToken=root' \
  --set='injector.enabled=true' \
  --set='injector.metrics.enabled=true' \
  --wait \
  --timeout=5m > /tmp/helm-vault.log 2>&1

kubectl -n vault rollout status deployment/vault-agent-injector --timeout=180s > /dev/null 2>&1

wait "$INSTALL_VAULT_PID"

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

kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n demo create serviceaccount webapp --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"
kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n vault create serviceaccount vault-agent-injector-init --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

WEBAPP_TEST_JWT=$(kubectl -n demo create token webapp --duration=10m 2>/dev/null)
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

kubectl -n vault delete job vault-agent-injector-init --ignore-not-found=true > /dev/null 2>&1
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
                if [ -n "\$WEBAPP_TEST_JWT" ]; then
                  vault write auth/kubernetes/login role="webapp" jwt="\$WEBAPP_TEST_JWT" > /dev/null
                fi
              done
EOF

if ! kubectl apply -f /tmp/vault-agent-injector-init-job.yaml > /dev/null; then
  echo "WARNING: Failed to create Vault initialization job. Manifest follows:"
  sed -n '1,220p' /tmp/vault-agent-injector-init-job.yaml
elif ! kubectl -n vault wait --for=condition=complete job/vault-agent-injector-init --timeout=240s > /tmp/vault-agent-injector-init.log 2>&1; then
  echo "WARNING: Vault initialization job did not complete. Recent logs:"
  echo "--- kubectl wait output ---"
  cat /tmp/vault-agent-injector-init.log || true
  echo "--- job describe ---"
  kubectl -n vault describe job vault-agent-injector-init || true
  echo "--- init pod status ---"
  kubectl -n vault get pods -l app=vault-agent-injector-init -o wide || true
  echo "--- init pod events ---"
  INIT_POD=$(kubectl -n vault get pod -l app=vault-agent-injector-init -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$INIT_POD" ]; then
    kubectl -n vault describe pod "$INIT_POD" | sed -n '/Events:/,$p' || true
  fi
  echo "--- init job logs ---"
  kubectl -n vault logs job/vault-agent-injector-init --tail=120 || true
else
  echo "Vault initialization job completed."
fi

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

cd /root
finish_setup