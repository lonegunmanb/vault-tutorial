# 第四步：Kubernetes：终止 leader Pod 触发选举，观察标签与 Service endpoints 跟随

正文 §3.4 给出了一个关键实践：用 `selector: vault-active=true` 创建一个**永远只指向当前 leader** 的 Service。Helm chart 已经默认创建了这样一个 Service——名为 `vault-active`。本步先确认它的 selector 与 endpoints 始终精确匹配标签视图，再主动 `kubectl delete pod` 杀掉当前 leader Pod，观察一次完整的"标签翻转 + Service endpoints 切换"。

## 4.1 确认 Helm chart 默认的 vault-active Service

```bash
kubectl -n vault get svc
kubectl -n vault get svc vault-active -o yaml \
  | grep -A 5 selector:
```

`selector` 中应当包含 `vault-active: "true"`——这正是正文 §3.4 中那个 YAML 片段的语义。

查看该 Service 当前的 endpoints：

```bash
kubectl -n vault get endpoints vault-active
```

`ENDPOINTS` 列只有一个 `<ip>:8200` 条目——其 `<ip>` 必然属于当前 leader Pod。再通过 endpointslice 进一步看到背后的 Pod 名（依不同 K8s 版本，输出 schema 可能略有差异）：

```bash
kubectl -n vault get endpointslice -l kubernetes.io/service-name=vault-active \
  -o jsonpath='{.items[*].endpoints[*].targetRef.name}{"\n"}'
```

记录此时的 leader Pod 名字（例如 `vault-0`）作为对照。

## 4.2 在 leader Pod 内做一次写入，便于稍后跨 Pod 复读

启用一个 KV v2 引擎并写入一条数据。通过 active service 写入即可，无需关心当前 leader 是谁：

```bash
LEADER_POD=$(kubectl -n vault get endpointslice \
  -l kubernetes.io/service-name=vault-active \
  -o jsonpath='{.items[0].endpoints[0].targetRef.name}')
echo "当前 leader Pod = $LEADER_POD"

kubectl -n vault exec "$LEADER_POD" -- env \
  VAULT_TOKEN="$ROOT_TOKEN_K8S" \
  vault secrets enable -path=demo-kv kv-v2

kubectl -n vault exec "$LEADER_POD" -- env \
  VAULT_TOKEN="$ROOT_TOKEN_K8S" \
  vault kv put demo-kv/hello message="written via active leader"
```

## 4.3 杀掉当前 leader Pod，触发重新选举

```bash
kubectl -n vault delete pod "$LEADER_POD"
```

被删掉的 Pod 会被 StatefulSet 自动重建，但它**会以 sealed 状态启动**——这是 raft + Shamir seal 的固有行为，与本节话题无关。在它重启完成之前，原本的 standby 中会有一个被选为新 leader：

```bash
echo "等待重新选举完成 ..."
for i in {1..30}; do
  active_count=$(kubectl -n vault get pods -l app.kubernetes.io/name=vault,vault-active=true \
                   --no-headers 2>/dev/null | wc -l)
  if [ "$active_count" = "1" ]; then
    echo "已有新 leader："
    kubectl -n vault get pods -l app.kubernetes.io/name=vault,vault-active=true
    break
  fi
  echo -n "."
  sleep 2
done
```

## 4.4 观察"标签翻转 + Service endpoints 跟随"

用与 §3.4 完全相同的一行命令再观察一次：

```bash
kubectl -n vault get pods -l app.kubernetes.io/name=vault \
  -L vault-active,vault-initialized,vault-perf-standby,vault-sealed,vault-version
```

预期：

- 原 leader Pod（被你 delete 掉的那一只）——重建后默认为 sealed，所以 `VAULT-SEALED=true`、`VAULT-ACTIVE=false`，且 `READY` 列暂时为 `0/1`；
- 剩余两只 Pod 中，新 leader 的 `VAULT-ACTIVE` 已经翻成 `true`，另一只仍为 `false`。

再看 Service endpoints：

```bash
kubectl -n vault get endpoints vault-active

kubectl -n vault get endpointslice -l kubernetes.io/service-name=vault-active \
  -o jsonpath='{.items[*].endpoints[*].targetRef.name}{"\n"}'
```

`vault-active` Service 的 endpoint 已经自动指向**新** leader Pod，没有任何手工操作介入。这就是正文 §3.4 中那一段配图所讲的事情：**抓娃娃机的爪子始终精准抓出当前 `vault-active=true` 的那只 Pod**。

通过 active service 复读 §4.2 写入的数据，验证应用侧"无感"地切到了新 leader：

```bash
kubectl -n vault exec "$(kubectl -n vault get pods \
  -l app.kubernetes.io/name=vault,vault-active=true \
  -o jsonpath='{.items[0].metadata.name}')" -- env \
  VAULT_TOKEN="$ROOT_TOKEN_K8S" \
  vault kv get demo-kv/hello
```

应当看到 `message=written via active leader`。

## 4.5 让重启的 Pod 重新 unseal 回到池中

被 delete 重建的 Pod 仍然 sealed。把它 unseal，让集群回到 3/3 健康状态：

```bash
RESTARTED_POD="$LEADER_POD"
echo -n "等待 $RESTARTED_POD 完成 raft 同步 "
for i in {1..30}; do
  init=$(kubectl -n vault exec "$RESTARTED_POD" -- \
           curl -sS http://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null \
           | jq -r '.initialized' 2>/dev/null)
  if [ "$init" = "true" ]; then
    echo " OK"
    break
  fi
  echo -n "."
  sleep 1
done

kubectl -n vault exec "$RESTARTED_POD" -- vault operator unseal "$UNSEAL_KEY_K8S"

# 等 readiness probe 转绿
kubectl -n vault wait --for=condition=Ready pod/"$RESTARTED_POD" --timeout=60s

# 再看一次标签视图
kubectl -n vault get pods -l app.kubernetes.io/name=vault \
  -L vault-active,vault-sealed,vault-version
```

`VAULT-SEALED` 应当全部变回 `false`。

## 4.6 这一步的核心闭环

学员观察到完整的一条链路：**Vault 内部 HA 状态 → Pod label → Service selector → Service endpoints → 客户端流量**——每一段都是 K8s 原生机制驱动的，整个过程不需要外部服务发现系统、不需要负载均衡器额外配置、应用侧也完全不感知 leader 换人。

至此，本实验完成了 6.7 节正文围绕两种 `service_registration` 实现的全部主线观察点：从 Consul 模式的"DNS 视角"，到 Kubernetes 模式的"Label 视角"——同一组概念在不同基础设施上的两种落地形态都在终端中跑了一遍。
