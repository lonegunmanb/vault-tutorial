# 第一步：启动 3 节点集群并定位 active / standby

## 1.1 启动并初始化

按 bootstrap → follower 顺序启动 3 个节点：

```bash
./start-node.sh 1
sleep 3
./start-node.sh 2
./start-node.sh 3
sleep 3
```

对 node-1 执行初始化（为简化课堂演示，使用 1/1 分片；生产环境请使用更高的分片数）：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh
```

先解封 node-1（bootstrap 节点初始化后立即可解封）：

```bash
vault operator unseal "$UNSEAL_KEY"
```

node-2 与 node-3 通过 `retry_join` 向 node-1 注册以加入集群，但该注册过程不会立即完成——两节点需要等待下一次重试周期，才能从 node-1 同步到"集群已完成初始化"这一状态。在该状态同步完成之前，对其执行 `vault operator unseal` 将返回 `Vault is not initialized` 错误，节点将持续保持 sealed 状态。

因此正确的做法是：**先轮询确认 follower 已感知到集群初始化状态（`initialized: true`），再执行 unseal 操作**。

```bash
for port in 8210 8220; do
  echo -n "等待 node @ ${port} 完成 retry_join "
  for i in {1..30}; do
    initialized=$(curl -sS "http://127.0.0.1:${port}/v1/sys/seal-status" | jq -r '.initialized')
    if [ "$initialized" = "true" ]; then
      echo " OK"
      break
    fi
    echo -n "."
    sleep 1
  done
  VAULT_ADDR=http://127.0.0.1:${port} vault operator unseal "$UNSEAL_KEY"
done
```

> 如果某个 follower 30 秒后仍 `initialized: false`，先看 `/var/log/vault-2.log` 或 `/var/log/vault-3.log`，最常见的原因是 node-1 还没 unsealed（retry_join 拉不到已初始化的状态）或者端口没起来。

确认 3 节点都已 unsealed：

```bash
for port in 8200 8210 8220; do
  curl -sS "http://127.0.0.1:${port}/v1/sys/seal-status" \
    | jq '{port: '${port}', sealed, cluster_id}'
done
```

`sealed` 三个都是 `false`，且 `cluster_id` 完全一致，即为成功。

## 1.2 用 `sys/leader` API 定位 active 节点

`sys/leader` 是一个**未授权的、专门用于查询 HA 状态**的端点。对每个节点都问一遍，就能区分谁是 active、谁是 standby、且 standby 知道当前 active 的 `api_addr` 是什么：

```bash
for port in 8200 8210 8220; do
  echo "=== node @ ${port} ==="
  curl -sS "http://127.0.0.1:${port}/v1/sys/leader" \
    | jq '{ha_enabled, is_self, leader_address, leader_cluster_address}'
done
```

预期输出：

- 其中一个节点 `is_self: true`、`leader_address` 等于自身的 `api_addr`——这就是 active；
- 另外两个节点 `is_self: false`、`leader_address` 等于上面那个节点的 `api_addr`——这就是 standby，并且它们已经知道 active 的可达地址（这正是 6.5 节 §2 所讲的"通过加密存储广播"的成果，从客户端角度看是一个直接的 API 字段）。

请记录此时哪个端口为 active、哪两个端口为 standby——后续步骤将反复使用。例如，若 active 为 8200，则 8210 / 8220 均为 standby，可从中任选其一作为本节实验的"目标 standby"。

## 1.3 这一步的核心闭环

集群已稳定运行，3 节点全部 unsealed，并且每个节点均可通过 `sys/leader` 报告"自身角色为 active 或 standby、当前 active 的对外地址"等信息。下一步将向 standby 节点直接发送请求，以观察默认的请求转发行为。
