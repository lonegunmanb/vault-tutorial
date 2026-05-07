# 第二步：查询 active / standby / vault 三个 DNS 端点

Consul 的服务发现层会按服务的健康检查结果动态决定 DNS 解析返回哪些节点。Vault 的健康检查由 Vault 自身上报，并被 Consul 在内部为 `vault` 服务自动绑定到三个标准 DNS 名上：

- `active.vault.service.consul`：当前活跃节点；
- `standby.vault.service.consul`：所有处于待命且已 unseal 的节点；
- `vault.service.consul`：所有已 unseal 的节点（无论活跃 / 待命）。

## 2.1 直接对 Consul DNS（127.0.0.1:8600）执行 dig

dev 模式下 Consul 的 DNS 监听在 `127.0.0.1:8600`，因此用 `dig` 时需要显式指定该端口：

```bash
echo "=== active 端点（应只返回 1 条 A 记录）==="
dig @127.0.0.1 -p 8600 active.vault.service.consul +short

echo "=== standby 端点（应返回 2 条 A 记录）==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul +short

echo "=== vault 端点（应返回 3 条 A 记录，全部已 unseal）==="
dig @127.0.0.1 -p 8600 vault.service.consul +short
```

由于全部 Vault 节点都监听在 `127.0.0.1` 上，A 记录的内容都会是 `127.0.0.1`，仅条数不同。如需进一步看到端口与 ServiceID，可以查询 SRV 记录：

```bash
dig @127.0.0.1 -p 8600 active.vault.service.consul SRV +short
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short
dig @127.0.0.1 -p 8600 vault.service.consul SRV +short
```

`active` 的 SRV 记录端口必然是 8200 / 8210 / 8220 中实际承担 leader 角色的那一个；`standby` 的两条 SRV 记录端口正是另外两个端口。

## 2.2 与 `sys/leader` API 交叉验证

为了证实"DNS 上看到的 active 与 Vault 自己认为的 leader 是同一个节点"，再用 Vault 的 `sys/leader` 端点交叉验证：

```bash
for port in 8200 8210 8220; do
  echo "=== node @ ${port} ==="
  curl -sS "http://127.0.0.1:${port}/v1/sys/leader" \
    | jq '{is_self, leader_address}'
done
```

`is_self: true` 的那一行的端口，必须与 §2.1 中 `active.vault.service.consul` 的 SRV 端口完全一致。

## 2.3 通过 Consul HTTP API 查看健康检查详情

DNS 视图的背后是 Consul 的健康检查机制。可以用 HTTP API 直接查看：

```bash
curl -sS http://127.0.0.1:8500/v1/health/service/vault \
  | jq '.[] | {ServiceID, ServicePort,
                Checks: [.Checks[] | {Name, Status, Output}]}'
```

正常情况下每个节点都会有一项状态为 `passing` 的 Vault 健康检查。

## 2.4 这一步的核心闭环

学员现在亲眼看到了三个 DNS 端点各自映射到 Vault 集群中不同子集的节点，并通过 `sys/leader` 与 Consul 的 `health/service` 端点交叉验证了两侧视图的一致性。下一步主动 seal 一个待命节点，看它如何在 DNS 解析结果中消失。
