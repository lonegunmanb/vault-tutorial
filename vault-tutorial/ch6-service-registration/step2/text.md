# 第二步：Consul：查询三个 DNS 端点并观察 sealed 节点自动隐身

Consul 服务发现层会按服务的健康检查结果动态决定 DNS 解析返回哪些节点。Vault 的健康检查由 Vault 自身上报，并被 Consul 在内部为 `vault` 服务自动绑定到三个标准 DNS 名上：

- `active.vault.service.consul`：当前活跃节点；
- `standby.vault.service.consul`：所有处于待命且已 unseal 的节点；
- `vault.service.consul`：所有已 unseal 的节点（无论活跃 / 待命）。

## 2.1 直接对 Consul DNS（127.0.0.1:8600）执行 dig

dev 模式下 Consul DNS 监听在 `127.0.0.1:8600`，因此 `dig` 时需显式指定该端口。由于全部 Vault 节点都监听在 `127.0.0.1` 上，A 记录的内容都会是 `127.0.0.1`，仅条数不同；改查 SRV 记录可同时看到端口与 ServiceID：

```bash
echo "=== active 端点（应只返回 1 条 SRV 记录）==="
dig @127.0.0.1 -p 8600 active.vault.service.consul SRV +short

echo "=== standby 端点（应返回 2 条 SRV 记录）==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short

echo "=== vault 端点（应返回 3 条 SRV 记录，全部已 unseal）==="
dig @127.0.0.1 -p 8600 vault.service.consul SRV +short
```

`active` 的 SRV 记录端口必然是 8200 / 8210 / 8220 中实际承担 leader 角色的那一个；`standby` 的两条 SRV 记录端口正是另外两个端口。

## 2.2 与 `sys/leader` API 交叉验证

为了证实"DNS 上看到的 active 与 Vault 自己认为的 leader 是同一节点"，再用 Vault 的 `sys/leader` 端点交叉验证：

```bash
for port in 8200 8210 8220; do
  echo "=== node @ ${port} ==="
  curl -sS "http://127.0.0.1:${port}/v1/sys/leader" \
    | jq '{is_self, leader_address}'
done
```

`is_self: true` 的那一行的端口，必须与 §2.1 中 `active.vault.service.consul` 的 SRV 端口完全一致。

## 2.3 主动 seal 一个待命节点，观察其从服务目录消失

正文已经指出："处于 sealed 状态的 Vault 节点会主动在健康检查中将自身标记为不健康，因此不会被 Consul 的服务发现层返回。" 下面把这句话变成可观察的现象。

从 §2.1 / §2.2 的结果中确认哪个端口是 active、哪两个端口是 standby。下面假设 `8200` 是 active、`8210` 是其中一个 standby——若实际情况不同，请将命令中的 `8210` 替换为任意一个 standby 端口。

记下当前 standby 集合，便于稍后比对：

```bash
echo "=== seal 之前的 standby 端点 ==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short
```

对 8210 节点执行 `vault operator seal`：

```bash
VAULT_ADDR=http://127.0.0.1:8210 vault operator seal
```

健康检查的更新存在数秒间隔（默认 `check_timeout` 为 `5s`）。等待至多 10 秒再观察：

```bash
sleep 10

echo "=== seal 之后的 standby 端点（应少 1 条）==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short

echo "=== seal 之后的 vault 端点（应少 1 条）==="
dig @127.0.0.1 -p 8600 vault.service.consul SRV +short

echo "=== seal 之后的 active 端点（应不变，仍是原 leader）==="
dig @127.0.0.1 -p 8600 active.vault.service.consul SRV +short
```

被 seal 的 8210 节点应当从 `standby.vault.service.consul` 与 `vault.service.consul` 中消失，但 `active.vault.service.consul` 不受影响。

进一步用 HTTP API 查看 Consul 端的健康检查状态：

```bash
curl -sS http://127.0.0.1:8500/v1/health/service/vault \
  | jq '.[] | {ServicePort, Checks: [.Checks[] | {Name, Status}]}'
```

被 seal 的节点对应的 Vault 健康检查会从 `passing` 变为 `critical`。

## 2.4 这一步的核心闭环

学员观察到："DNS 视角"的拓扑随节点封印状态实时变化——sealed 节点对客户端而言"自动隐身"，无需任何客户端侧改造，也无需运维手工调整 Consul 的 service catalog。Consul 模式的核心机制至此已完成可观察的复现。

下一步切换到 Kubernetes 模式：用 Helm 把 HA Vault 部署到 K8s，观察 `service_registration "kubernetes"` 块如何把同样的状态信息写到 Pod label 上。
