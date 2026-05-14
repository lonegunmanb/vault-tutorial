# 第二步：K8s ServiceAccount → Vault → 同一份 PostgreSQL 动态凭据

第一步已经把"AWS IAM → PostgreSQL"那条流水线跑通了。本步换上完全不
同的 Phase 1 认证方法：**Kubernetes ServiceAccount**。需要重点观察的
是——`database/config/postgres-broker` 与 `database/roles/readonly`
这两条配置**全程不会被修改**，但同一条 `database/creds/readonly` 端点
会照样为 K8s 工作负载签发临时 PG 账号。这就是 [9.6 章正文](https://lonegunmanb.github.io/vault-tutorial/ch9-identity-broker-postgres.html)
末尾反复强调的"换上游、不换下游"。

> 端到端流水线：Pod 内 `kubectl create token` → ServiceAccount JWT →
> `vault write auth/kubernetes/login` → Vault token → `vault read
> database/creds/readonly` → username/password → 直连 PostgreSQL。

## 2.1 启用 Vault kubernetes auth method

回到 root token（如果还在第一步末尾的状态，已经回到 root；保险起见显
式 export 一次）：

```bash
export VAULT_TOKEN=root
```

创建专门给 Vault 调 TokenReview API 的 reviewer ServiceAccount：

```bash
kubectl create namespace vault-system
kubectl create serviceaccount vault-reviewer -n vault-system

kubectl create clusterrolebinding vault-reviewer-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-system:vault-reviewer
```

抓出 reviewer JWT、API server 地址、CA 证书：

```bash
REVIEWER_JWT=$(kubectl create token vault-reviewer -n vault-system --duration=1h)
K8S_HOST=$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
K8S_CA_CERT=/tmp/k8s-ca.crt
kubectl config view --raw --minify \
  -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "$K8S_CA_CERT"

echo "K8S_HOST=$K8S_HOST"
ls -l "$K8S_CA_CERT"
```

启用 kubernetes auth 并写入连接配置：

```bash
vault auth enable kubernetes

vault write auth/kubernetes/config \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@"$K8S_CA_CERT"

vault read auth/kubernetes/config
```

回读时 `token_reviewer_jwt_set` 应为 `true`。

## 2.2 创建工作负载 ServiceAccount 与对应的 Vault role

注意：本步**不创建新的 Vault policy**——直接复用第一步写的
`db-readonly`。这是本节正文末尾"换上游、不换下游"的字面体现。

```bash
kubectl create namespace demo
kubectl create serviceaccount app-k8s -n demo

vault write auth/kubernetes/role/app-k8s \
  bound_service_account_names=app-k8s \
  bound_service_account_namespaces=demo \
  audience=vault-broker \
  token_policies=db-readonly \
  token_ttl=15m

vault read auth/kubernetes/role/app-k8s
```

> `token_policies=db-readonly` 与第一步 `auth/aws/role/app-aws` 上挂的
> 是**同一条** policy。`bound_service_account_*` 把 Phase 1 的可登录
> 身份精确锁定到 `demo/app-k8s`——第三方 SA 即使签出 JWT 也登不进。

## 2.3 在 Pod 里签 ServiceAccount JWT 并登录 Vault

为了让流水线完全在"应用 Pod 视角"中跑通，跑一个 Pod 进去操作。Pod 用
`serviceAccountName: app-k8s` 启动，进 Pod 后我们在 Pod 内安装 vault
CLI、用 `kubectl create token` 签 JWT、然后 `vault write
auth/kubernetes/login` 换 Vault token。

> Killercoda 单节点集群里 Vault 跑在主机网络的 `127.0.0.1:8200`，Pod
> 默认 podCIDR 与主机 net namespace 隔离，因此实验里把 Pod 用
> `hostNetwork: true` 接入主机网络栈，这样 Pod 内访问 `127.0.0.1:8200`
> 就直达本机 Vault；同样原因，Pod 内的 `kubectl` 直接通过 `KUBECONFIG`
> 走 K8s API。这是**实验环境专用**的简化，生产里 Vault 通常以
> Service / Ingress 形式暴露给集群。

启动 Pod（`tail -f /dev/null` 让 Pod 一直留着）：

```bash
kubectl run app-k8s-pod \
  --image=ubuntu:22.04 \
  --serviceaccount=app-k8s -n demo \
  --restart=Never \
  --overrides='{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}' \
  --command -- sleep infinity

# 等 Pod Ready
kubectl wait --for=condition=Ready pod/app-k8s-pod -n demo --timeout=120s
```

把 vault 二进制 + KUBECONFIG + CA 拷到 Pod，避免再装一次：

```bash
kubectl cp -n demo "$(which vault)" app-k8s-pod:/usr/local/bin/vault
kubectl cp -n demo "$KUBECONFIG" app-k8s-pod:/root/.kube-config
kubectl cp -n demo "$K8S_CA_CERT" app-k8s-pod:/tmp/k8s-ca.crt
kubectl exec -n demo app-k8s-pod -- chmod +x /usr/local/bin/vault
```

> `kubectl cp` 走的是 K8s API + kubelet 的 file copy 路径，不依赖 Pod
> 内有 `tar` 之外的工具；ubuntu:22.04 默认带 `tar`。

进 Pod，用 ServiceAccount 自身的 projected token 走 K8s API 给自己签
一枚 audience 为 `vault-broker` 的短期 JWT。

> Pod 内默认挂在 `/var/run/secrets/kubernetes.io/serviceaccount/token`
> 的那枚 token 由 kubelet 注入，audience 是 K8s API server 自身，**不
> 是** `vault-broker`，会被我们 role 上的 audience 约束拒掉；所以这里
> 用 `kubectl create token --audience=vault-broker` 现签一枚正确受众的
> token——这是 K8s 1.22+ TokenRequest API 的标准用法，Vault 4.4 章实
> 验中也一致采用这种方式。

```bash
kubectl exec -n demo app-k8s-pod -- bash -c '
set -e
export KUBECONFIG=/root/.kube-config
export VAULT_ADDR=http://127.0.0.1:8200

# 用自己的 SA 给自己签一枚 audience=vault-broker 的短期 JWT
APP_JWT=$(kubectl create token app-k8s -n demo --audience=vault-broker --duration=10m)
echo "APP_JWT length: ${#APP_JWT}"

# Phase 1：把 JWT 提交给 Vault，换 Vault token
LOGIN_JSON=$(vault write -format=json auth/kubernetes/login role=app-k8s jwt="$APP_JWT")
echo "$LOGIN_JSON" | grep -E "policies|service_account" | head -10

VAULT_TOKEN=$(echo "$LOGIN_JSON" | grep -oE "\"client_token\":[^,]*" | head -1 | cut -d\" -f4)
echo "VAULT_TOKEN=${VAULT_TOKEN:0:20}..."
echo "$VAULT_TOKEN" > /tmp/vault-token
'
```

`policies` 应包含 `db-readonly`，`metadata` 应包含
`service_account_name: app-k8s` / `service_account_namespace: demo`。
**这两条 metadata 都来自 Vault 内部的 TokenReview 验证**——它已经回调
集群 API server 确认过这枚 JWT 不是伪造的。

## 2.4 在 Pod 里申领同一条 database/creds/readonly

```bash
kubectl exec -n demo app-k8s-pod -- bash -c '
set -e
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(cat /tmp/vault-token)

# Phase 2 + Phase 3：申领临时 PG 凭据
CRED=$(vault read -format=json database/creds/readonly)
PG_USER=$(echo "$CRED" | grep -oE "\"username\":[^,]*" | head -1 | cut -d\" -f4)
PG_PASS=$(echo "$CRED" | grep -oE "\"password\":[^,]*" | head -1 | cut -d\" -f4)
LEASE_ID=$(echo "$CRED" | grep -oE "\"lease_id\":[^,]*" | head -1 | cut -d\" -f4)

echo "PG_USER=$PG_USER"
echo "LEASE_ID=$LEASE_ID"
echo "$PG_USER" > /tmp/pg-user
echo "$PG_PASS" > /tmp/pg-pass
echo "$LEASE_ID" > /tmp/lease-id
'
```

这枚 `PG_USER` 形如 `v-kubernetes-readonly-xxxxxxxx-...`——前缀里的
`kubernetes` 与第一步的 `iam` 相对应，是 Vault 自动写入的、可被审计
反向追溯的 metadata。**没有改动任何 PG 端配置就发出来了**。

回到主机端从 PG 旁路确认：

```bash
PG_USER_K8S=$(kubectl exec -n demo app-k8s-pod -- cat /tmp/pg-user)
echo "PG_USER from Pod = $PG_USER_K8S"

PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='$PG_USER_K8S';"
# 应输出 $PG_USER_K8S
```

## 2.5 在 Pod 里用临时账号实连 PostgreSQL 跑业务 SQL

Pod 已经在 `hostNetwork=true` 下，直接连主机的 PG 即可。先在 Pod 里
装一下 psql 客户端：

```bash
kubectl exec -n demo app-k8s-pod -- bash -c '
apt-get update -qq && apt-get install -y -qq postgresql-client > /dev/null 2>&1
PG_USER=$(cat /tmp/pg-user)
PG_PASS=$(cat /tmp/pg-pass)

PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -U "$PG_USER" -d postgres \
  -c "SELECT k, v FROM demo.kv ORDER BY k;"
'
```

应输出 `demo.kv` 的两行业务数据——**与第一步看到的完全相同**。这一刻
就是本节正文末尾"换上游、不换下游"的字面证据。

## 2.6 主动 revoke lease，验证临时账号在 PG 端被 DROP

```bash
LEASE_FROM_POD=$(kubectl exec -n demo app-k8s-pod -- cat /tmp/lease-id)
echo "LEASE = $LEASE_FROM_POD"

vault lease revoke "$LEASE_FROM_POD"
sleep 2

PGPASSWORD=rootpassword psql -h 127.0.0.1 -U root -d postgres -tAc \
  "SELECT count(*) FROM pg_roles WHERE rolname='$PG_USER_K8S';"
# 应输出 0
```

## 2.7 反演：用错的 audience / 错的 SA 都登不进来

仍在 Pod 内：

```bash
# 反演 1：用 K8s API server 默认 audience 签的 token
kubectl exec -n demo app-k8s-pod -- bash -c '
export KUBECONFIG=/root/.kube-config
export VAULT_ADDR=http://127.0.0.1:8200
WRONG_JWT=$(kubectl create token app-k8s -n demo --duration=10m)
vault write auth/kubernetes/login role=app-k8s jwt="$WRONG_JWT" 2>&1 | head -5
'
# 应看到 audience 不匹配的错误（invalid audience / aud claim 等）
```

```bash
# 反演 2：用一个完全不在 role bound_service_account_names 里的 SA
kubectl create serviceaccount intruder -n demo

kubectl exec -n demo app-k8s-pod -- bash -c '
export KUBECONFIG=/root/.kube-config
export VAULT_ADDR=http://127.0.0.1:8200
INTRUDER_JWT=$(kubectl create token intruder -n demo --audience=vault-broker --duration=10m)
vault write auth/kubernetes/login role=app-k8s jwt="$INTRUDER_JWT" 2>&1 | head -5
'
# 应看到类似 "service account name not authorized" 的拒绝
```

> 这两条反演直接证实：Vault 在 Phase 1 的判定**不只看 JWT 是否有效**，
> 还会用 role 上的 `bound_service_account_*`、`audience` 等字段做二次
> 拦截——**外部身份合法 ≠ 该身份在 Vault 这条 role 上有登录权**。

---

## ✅ 验收

- [ ] Pod 内 `vault write auth/kubernetes/login role=app-k8s jwt=...` 成功，token 上挂 `db-readonly` policy
- [ ] Pod 内 `vault read database/creds/readonly` 成功，返回 `v-kubernetes-readonly-...` 账号
- [ ] Pod 内用临时账号能 `SELECT * FROM demo.kv` 拿到与第一步**完全相同**的业务数据
- [ ] `vault lease revoke` 后 PG 端临时账号消失
- [ ] `audience` 错 / SA 错时登录被 Vault 拒（**Phase 1 的硬约束**）

> **核心闭环**：本步全程没有动 `database/config/postgres-broker` 与
> `database/roles/readonly`——同一条 `database/creds/readonly` 端点
> 在第一步为 AWS IAM 身份发凭据、在本步为 K8s ServiceAccount 发凭据。
> 这就是 Vault identity brokering 范式的真正抽象：**身份与凭据彻底
> 解耦**。下面的实验完成页会把整条流水线再做一次概念回顾。
