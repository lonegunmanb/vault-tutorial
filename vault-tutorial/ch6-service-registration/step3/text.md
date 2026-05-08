# 第三步：Kubernetes：用 Helm 部署 HA Vault 并观察 Pod 标签

本步把演示焦点从 Consul 切换到 Kubernetes：在同一台 Killercoda 主机的 K8s 集群上，用官方 `hashicorp/vault` Helm chart 部署 3 副本 HA Vault（存储后端为 Integrated Storage），并观察 Vault 进程**反向把节点状态打到自己所在 Pod 的 label** 上。

## 3.1 释放宿主机资源

宿主机上的 3 个 Vault 进程会与即将启动的 K8s Pod 争抢端口，先把它们停掉。Consul 与本步无关，可保留也可一并 `pkill consul`：

```bash
./stop-host-vaults.sh
pgrep -af 'vault server' || echo "已无宿主机 Vault 进程"
```

## 3.2 用 Helm 部署 3 副本 HA Vault（含 raft）

先确认 helm 仓库已就绪（环境初始化时已执行过，幂等再来一次也无妨）：

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null
helm repo update | tail -n 5
```

写入 values 文件并部署到 `vault` namespace：

```bash
kubectl create namespace vault 2>/dev/null

cat > /root/vault-helm-values.yaml <<'EOF'
global:
  enabled: true
server:
  image:
    repository: hashicorp/vault
    tag: 1.19.2
  logLevel: info
  affinity: ""
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
EOF

helm install vault hashicorp/vault \
  --namespace vault \
  -f /root/vault-helm-values.yaml \
  --wait --timeout 3m || true
```

> Helm chart 在 `server.ha.enabled=true` 且 `server.ha.raft.enabled=true` 时，会**自动**在生成的 vault.hcl 里写入 `service_registration "kubernetes" {}`，并通过 Downward API 注入 `VAULT_K8S_NAMESPACE` 与 `VAULT_K8S_POD_NAME` 这两个环境变量，同时为 Pod 的 ServiceAccount 配上对 `pods` 资源的 `get`、`update`、`patch` 权限——也就是说，正文 §3.1 与 §3.2 描述的"声明意图 + RBAC"两件事都已经被 chart 替你做完。

等 3 个 Pod 都进入 Running（`--wait` 等的是 readiness probe，但 Vault 在初始化前 ready 永远不会是 true，所以这里允许超时）：

```bash
kubectl -n vault get pods -l app.kubernetes.io/name=vault
```

预期看到 `vault-0` / `vault-1` / `vault-2` 三个 Pod 处于 Running，但 READY 列形如 `0/1`——这是预期的，因为还没 init/unseal。

## 3.3 在 vault-0 内执行 init 与 unseal

让 `vault-0` 成为初始化节点（同样为简化课堂演示使用 1/1 分片）：

```bash
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > /root/k8s-init.json

UNSEAL_KEY_K8S=$(jq -r '.unseal_keys_b64[0]' /root/k8s-init.json)
ROOT_TOKEN_K8S=$(jq -r '.root_token' /root/k8s-init.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY_K8S='${UNSEAL_KEY_K8S}'
export ROOT_TOKEN_K8S='${ROOT_TOKEN_K8S}'
EOF
source /etc/profile.d/vault.sh

kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL_KEY_K8S"
```

让 `vault-1` 与 `vault-2` 通过 raft join 加入集群（chart 模板默认通过 `vault-internal` headless service 互联），再 unseal：

```bash
for pod in vault-1 vault-2; do
  kubectl -n vault exec "$pod" -- \
    vault operator raft join http://vault-0.vault-internal:8200 || true

  # 与 step1 中宿主机场景同理：retry/raft join 是异步的，
  # 必须先看到 initialized=true 再 unseal，否则会报 "Vault is not initialized"。
  echo -n "等待 $pod 完成 raft join "
  for i in {1..30}; do
    init=$(kubectl -n vault exec "$pod" -- \
             curl -sS http://127.0.0.1:8200/v1/sys/seal-status | jq -r '.initialized')
    if [ "$init" = "true" ]; then
      echo " OK"
      break
    fi
    echo -n "."
    sleep 1
  done
  kubectl -n vault exec "$pod" -- vault operator unseal "$UNSEAL_KEY_K8S"
done
```

等 readiness probe 转绿（unseal 之后才会变 ready）：

```bash
kubectl -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --timeout=120s
kubectl -n vault get pods -l app.kubernetes.io/name=vault
```

`READY` 列应当全部变为 `1/1`。

## 3.4 看 Vault 写到 Pod 上的标签

正文 §3.3 列出了五个标签：`vault-active`、`vault-initialized`、`vault-perf-standby`、`vault-sealed`、`vault-version`。直接用 `kubectl get pod -L` 把它们打到表格里：

```bash
kubectl -n vault get pods -l app.kubernetes.io/name=vault \
  -L vault-active,vault-initialized,vault-perf-standby,vault-sealed,vault-version
```

预期：

- 三只 Pod 中有且仅有一只的 `VAULT-ACTIVE` 列是 `true`，其余两只是 `false`；
- 全部 `VAULT-INITIALIZED=true`、`VAULT-SEALED=false`、`VAULT-PERF-STANDBY=false`、`VAULT-VERSION=1.19.2`。

也可以单独看某一只 Pod 的完整 label 集：

```bash
kubectl -n vault get pod vault-0 -o jsonpath='{.metadata.labels}' | jq
```

应当能看到 `vault-active`、`vault-sealed` 等 key。

## 3.5 验证 Vault 自身的 leader 视图与标签一致

把"标签视角"与"Vault 自报视角"交叉验证一遍：

```bash
for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ==="
  kubectl -n vault exec "$pod" -- \
    curl -sS http://127.0.0.1:8200/v1/sys/leader \
    | jq '{is_self, leader_address}'
done
```

`is_self: true` 的那一只 Pod，必须正是上一步 `VAULT-ACTIVE=true` 的那一只。

## 3.6 这一步的核心闭环

学员观察到：在 K8s 上启用 `service_registration "kubernetes"` 后，Vault 的活跃 / 待命 / 封印状态被实时打到 Pod label 上，**完全无需任何外部服务发现系统**。下一步把 Helm chart 默认创建的 `vault-active` Service 与这些标签对接起来，并主动 kill 当前 leader Pod，看 selector 视图如何随重新选举自动迁移。
