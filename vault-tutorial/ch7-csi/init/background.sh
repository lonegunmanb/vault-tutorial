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

kubectl create clusterrolebinding vault-tokenreview-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

echo "Configuring Vault Kubernetes auth and KV data..."
kubectl -n vault exec vault-0 -- /bin/sh -c '
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

vault kv put secret/csi/app \
  username="csi-user" \
  password="initial-password" \
  api_key="csi-api-key" > /dev/null

vault policy write csi-app - > /dev/null <<EOF
path "secret/data/csi/app" {
  capabilities = ["read"]
}
EOF

vault auth enable kubernetes > /dev/null 2>&1 || true
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  > /dev/null

vault write auth/kubernetes/role/csi-app \
  bound_service_account_names="app" \
  bound_service_account_namespaces="csi-demo" \
  token_policies="csi-app" \
  token_ttl="20m" \
  > /dev/null
'

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