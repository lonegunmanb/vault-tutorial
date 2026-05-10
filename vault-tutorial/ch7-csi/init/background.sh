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
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1

echo "Installing Secrets Store CSI driver..."
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  > /tmp/helm-csi-driver.log 2>&1

kubectl -n kube-system rollout status daemonset/csi-secrets-store-secrets-store-csi-driver --timeout=180s \
  > /tmp/csi-driver-rollout.log 2>&1 || true

echo "Installing Vault dev server and Vault CSI provider..."
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" \
  --set "csi.enabled=true" \
  --set "injector.enabled=false" \
  > /tmp/helm-vault.log 2>&1

kubectl -n vault rollout status statefulset/vault --timeout=180s > /tmp/vault-rollout.log 2>&1 || true
kubectl -n vault rollout status daemonset/vault-csi-provider --timeout=180s > /tmp/vault-csi-rollout.log 2>&1 || true

echo "Waiting for Vault pod..."
for i in $(seq 1 120); do
  if kubectl -n vault get pod vault-0 2>/dev/null | grep -q "Running"; then
    break
  fi
  sleep 1
done

kubectl create namespace csi-demo --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n csi-demo create serviceaccount app --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

VAULT_SERVER_SA=$(kubectl -n vault get pod vault-0 -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
VAULT_SERVER_SA="${VAULT_SERVER_SA:-vault}"
kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount="vault:${VAULT_SERVER_SA}" \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
kubectl -n vault create serviceaccount vault-csi-init --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

CSI_TEST_JWT=$(kubectl -n csi-demo create token app --duration=10m 2>/dev/null)
decode_jwt_issuer() {
  local payload
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr -- '-_' '+/')
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.iss // empty'
}
K8S_ISSUER=$(decode_jwt_issuer "$CSI_TEST_JWT")
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

echo "Configuring Vault Kubernetes auth and KV data..."
kubectl -n vault delete job vault-csi-init --ignore-not-found=true > /dev/null 2>&1
cat > /tmp/vault-csi-init-job.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-csi-init
  namespace: vault
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: vault-csi-init
    spec:
      restartPolicy: Never
      serviceAccountName: vault-csi-init
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
            - name: CSI_TEST_JWT
              value: "${CSI_TEST_JWT}"
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
                vault kv put secret/csi/app \
                  username="csi-user" \
                  password="initial-password" \
                  api_key="csi-api-key" > /dev/null

                printf '%s\n' \
                  'path "secret/data/csi/app" {' \
                  '  capabilities = ["read"]' \
                  '}' \
                  | vault policy write csi-app - > /dev/null

                vault write auth/kubernetes/role/csi-app \
                  bound_service_account_names="app" \
                  bound_service_account_namespaces="csi-demo" \
                  token_policies="csi-app" \
                  token_ttl="20m" > /dev/null

                vault read auth/kubernetes/role/csi-app > /dev/null
                vault kv get secret/csi/app > /dev/null
                if [ -n "\$CSI_TEST_JWT" ]; then
                  vault write auth/kubernetes/login role="csi-app" jwt="\$CSI_TEST_JWT" > /dev/null
                fi
              done
EOF

if ! kubectl apply -f /tmp/vault-csi-init-job.yaml > /dev/null; then
  echo "WARNING: Failed to create Vault CSI initialization job. Manifest follows:"
  sed -n '1,240p' /tmp/vault-csi-init-job.yaml
elif ! kubectl -n vault wait --for=condition=complete job/vault-csi-init --timeout=240s > /tmp/vault-csi-init.log 2>&1; then
  echo "WARNING: Vault CSI initialization job did not complete. Recent logs:"
  echo "--- kubectl wait output ---"
  cat /tmp/vault-csi-init.log || true
  echo "--- job describe ---"
  kubectl -n vault describe job vault-csi-init || true
  echo "--- init pod status ---"
  kubectl -n vault get pods -l app=vault-csi-init -o wide || true
  echo "--- init pod events ---"
  INIT_POD=$(kubectl -n vault get pod -l app=vault-csi-init -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$INIT_POD" ]; then
    kubectl -n vault describe pod "$INIT_POD" | sed -n '/Events:/,$p' || true
  fi
  echo "--- init job logs ---"
  kubectl -n vault logs job/vault-csi-init --tail=120 || true
else
  echo "Vault CSI initialization job completed."
fi

SPC_VERSIONS=$(kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{" "}{end}' 2>/dev/null)
if echo "$SPC_VERSIONS" | grep -qw "v1"; then
  SPC_API_VERSION="secrets-store.csi.x-k8s.io/v1"
else
  SPC_FIRST_VERSION=$(echo "$SPC_VERSIONS" | awk '{print $1}')
  SPC_API_VERSION="secrets-store.csi.x-k8s.io/${SPC_FIRST_VERSION:-v1alpha1}"
fi

cat > /root/csi-file-mount.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: csi-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
  namespace: csi-demo
---
apiVersion: ${SPC_API_VERSION}
kind: SecretProviderClass
metadata:
  name: vault-kv-files
  namespace: csi-demo
spec:
  provider: vault
  parameters:
    roleName: "csi-app"
    vaultAddress: "http://vault.vault.svc:8200"
    vaultAuthMountPath: "kubernetes"
    objects: |
      - objectName: "appUsername"
        secretPath: "secret/data/csi/app"
        secretKey: "username"
      - objectName: "appPassword"
        secretPath: "secret/data/csi/app"
        secretKey: "password"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-file-app
  namespace: csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-file-app
  template:
    metadata:
      labels:
        app: csi-file-app
    spec:
      serviceAccountName: app
      containers:
        - name: app
          image: busybox:1.36
          command: ["/bin/sh", "-c", "echo mounted files:; ls -l /mnt/secrets-store; while true; do sleep 3600; done"]
          volumeMounts:
            - name: vault-kv
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: vault-kv
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: vault-kv-files
EOF

cat > /root/csi-bad-sa.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-bad-sa
  namespace: csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-bad-sa
  template:
    metadata:
      labels:
        app: csi-bad-sa
    spec:
      serviceAccountName: default
      containers:
        - name: app
          image: busybox:1.36
          command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
          volumeMounts:
            - name: vault-kv
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: vault-kv
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: vault-kv-files
EOF

cat > /root/csi-env-sync.yaml <<EOF
apiVersion: ${SPC_API_VERSION}
kind: SecretProviderClass
metadata:
  name: vault-kv-env
  namespace: csi-demo
spec:
  provider: vault
  secretObjects:
    - secretName: vault-csi-app-env
      type: Opaque
      data:
        - objectName: appUsername
          key: username
        - objectName: appPassword
          key: password
  parameters:
    roleName: "csi-app"
    vaultAddress: "http://vault.vault.svc:8200"
    vaultAuthMountPath: "kubernetes"
    objects: |
      - objectName: "appUsername"
        secretPath: "secret/data/csi/app"
        secretKey: "username"
      - objectName: "appPassword"
        secretPath: "secret/data/csi/app"
        secretKey: "password"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-env-syncer
  namespace: csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-env-syncer
  template:
    metadata:
      labels:
        app: csi-env-syncer
    spec:
      serviceAccountName: app
      containers:
        - name: app
          image: busybox:1.36
          command: ["/bin/sh", "-c", "echo synced via CSI volume; ls -l /mnt/secrets-store; while true; do sleep 3600; done"]
          volumeMounts:
            - name: vault-kv
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: vault-kv
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: vault-kv-env
EOF

cat > /root/csi-env-app.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-env-app
  namespace: csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-env-app
  template:
    metadata:
      labels:
        app: csi-env-app
    spec:
      serviceAccountName: app
      containers:
        - name: app
          image: busybox:1.36
          command: ["/bin/sh", "-c", "env | grep '^APP_'; while true; do sleep 3600; done"]
          env:
            - name: APP_USERNAME
              valueFrom:
                secretKeyRef:
                  name: vault-csi-app-env
                  key: username
            - name: APP_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: vault-csi-app-env
                  key: password
EOF

wait "$INSTALL_VAULT_PID"

cd /root
finish_setup