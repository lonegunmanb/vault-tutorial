# 第一步：Consul：启动 dev agent 与 3 节点 Vault 集群并完成注册

本步在宿主机上把 Consul + 3 节点 Vault Raft 集群跑起来，并通过 Consul HTTP catalog API 验证 `service_registration "consul"` 块确实把 Vault 节点注册进了服务目录。

## 1.1 启动 Consul dev agent

启动 Consul，使其 HTTP API 监听 `127.0.0.1:8500`，DNS 监听 `127.0.0.1:8600`：

```bash
./start-consul.sh
```

确认 Consul 已经选出自己的 leader（dev 模式下就是它自己一个节点）：

```bash
curl -sS http://127.0.0.1:8500/v1/status/leader
```

输出形如 `"127.0.0.1:8300"` 即为成功。

## 1.2 顺序启动 3 个 Vault 节点

按 bootstrap → follower 顺序启动 3 个节点：

```bash
./start-node.sh 1
sleep 3
./start-node.sh 2
./start-node.sh 3
sleep 3
```

对 node-1 执行初始化（为简化课堂演示使用 1/1 分片；生产环境请使用更高的分片数）：

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

先解封 node-1：

```bash
vault operator unseal "$UNSEAL_KEY"
```

node-2 与 node-3 通过 `retry_join` 向 node-1 注册以加入集群，但该注册过程不会立即完成——两节点需等待下一次重试周期，才能从 node-1 同步到"集群已完成初始化"这一状态。在该状态同步完成之前对其执行 `vault operator unseal` 将返回 `Vault is not initialized` 错误，节点将持续保持 sealed。轮询确认 follower 已感知到集群初始化状态后再 unseal：

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

确认 3 节点都已 unsealed：

```bash
for port in 8200 8210 8220; do
  curl -sS "http://127.0.0.1:${port}/v1/sys/seal-status" \
    | jq '{port: '${port}', sealed, cluster_id}'
done
```

`sealed` 三个都是 `false`、且 `cluster_id` 完全一致即为成功。

## 1.3 通过 Consul HTTP catalog 观察注册结果

`service_registration "consul"` 块生效后，Vault 会自动通过本机 Consul agent 把自身注册为名为 `vault` 的服务。直接询问 Consul：

```bash
curl -sS http://127.0.0.1:8500/v1/catalog/services | jq
```

应当看到键 `"vault"` 出现在结果中。

进一步查看 `vault` 服务下注册的 3 个实例（每个 Vault 节点都会以独立的 Service ID 出现）：

```bash
curl -sS http://127.0.0.1:8500/v1/catalog/service/vault \
  | jq '.[] | {ServiceID, ServiceAddress, ServicePort, ServiceTags}'
```

预期会看到 3 条记录、`ServicePort` 分别落在 8200 / 8210 / 8220 上。

## 1.4 这一步的核心闭环

存储后端选用了 Raft，但因为加上了 `service_registration "consul"` 块，3 个 Vault 节点已经主动把自身注册进了 Consul 的服务目录，并附带 Vault 自动维护的健康检查。下一步把 Consul 提供的三个标准 DNS 端点拉出来分别查询，并通过 seal 一个待命节点观察 Consul 健康检查的实时反应。
