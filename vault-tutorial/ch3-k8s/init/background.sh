#!/bin/bash
set +e

source /root/setup-common.sh

# ─────────────────────────────────────────────────────────
# 并行：装 Vault + 装 jq；Kubernetes 由 Killercoda 后端镜像预置
# ─────────────────────────────────────────────────────────
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1

# Killercoda 的 kubernetes-kubeadm-1node 镜像已内置单节点集群。
# 这里只等待 API server 与 node ready，并把 kubeconfig 显式写入登录 shell。
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

# 持久化 KUBECONFIG 给所有 shell
cat > /etc/profile.d/kubernetes.sh <<EOF
export KUBECONFIG='${KUBECONFIG:-/root/.kube/config}'
EOF
chmod +x /etc/profile.d/kubernetes.sh
grep -q "KUBECONFIG=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/kubernetes.sh >> /root/.bashrc

# ─────────────────────────────────────────────────────────
# 创建 manager SA + ClusterRole + ClusterRoleBinding
# ─────────────────────────────────────────────────────────
kubectl create namespace vault-system 2>/dev/null
kubectl create serviceaccount vault-manager -n vault-system 2>/dev/null

kubectl apply -f - > /dev/null 2>&1 <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vault-kubernetes-secrets
rules:
- apiGroups: [""]
  resources: ["serviceaccounts","serviceaccounts/token"]
  verbs: ["create","update","delete","get","list","watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings","clusterrolebindings"]
  verbs: ["create","update","delete","get","list","watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles","clusterroles"]
  verbs: ["bind","escalate","create","update","delete","get","list","watch"]
EOF

kubectl create clusterrolebinding vault-kubernetes-secrets-binding \
  --clusterrole=vault-kubernetes-secrets \
  --serviceaccount=vault-system:vault-manager 2>/dev/null

# ─────────────────────────────────────────────────────────
# K8s 1.24+ 不再自动给 SA 生成 Secret，必须手工创建
# ─────────────────────────────────────────────────────────
kubectl apply -f - > /dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: vault-manager-token
  namespace: vault-system
  annotations:
    kubernetes.io/service-account.name: "vault-manager"
type: kubernetes.io/service-account-token
EOF

# 等 controller 把 token 填进去
MANAGER_TOKEN=""
for i in $(seq 1 30); do
  MANAGER_TOKEN=$(kubectl get secret vault-manager-token -n vault-system \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -n "$MANAGER_TOKEN" ]; then break; fi
  sleep 1
done

K8S_HOST=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
K8S_CA_CERT=$(kubectl get secret vault-manager-token -n vault-system \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

# ─────────────────────────────────────────────────────────
# 预置实验用的 SA / Role / RoleBinding
# ─────────────────────────────────────────────────────────
kubectl create serviceaccount viewer-sa -n default 2>/dev/null

kubectl apply -f - > /dev/null 2>&1 <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
subjects:
- kind: ServiceAccount
  name: viewer-sa
  namespace: default
EOF

# ─────────────────────────────────────────────────────────
# 等 vault 装完，启动 Vault Dev
# ─────────────────────────────────────────────────────────
wait "$INSTALL_VAULT_PID"
start_vault_dev

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# 启用 kubernetes/ 引擎并写入连接配置
vault secrets enable kubernetes 2>/dev/null
vault write kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT" \
  service_account_jwt="$MANAGER_TOKEN" > /dev/null 2>&1

cd /root
finish_setup
