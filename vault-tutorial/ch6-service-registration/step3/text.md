# 第三步：Seal 一个待命节点，观察它从服务目录消失

6.7 节正文中提到："处于 sealed 状态的 Vault 节点会主动在健康检查中将自身标记为不健康，因此不会被 Consul 的服务发现层返回。" 这一步把这句话变成可观察的现象。

## 3.1 选定一个待命节点

先从第 1 步 / 第 2 步的结果中确认哪个端口是 active、哪两个端口是 standby。下面假设 `8200` 是 active、`8210` 与 `8220` 是 standby——若实际情况不同，请将下面命令中的 `8210` 替换为任意一个 standby 端口。

记下当前 standby 集合，便于稍后比对：

```bash
echo "=== seal 之前的 standby 端点 ==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short
```

## 3.2 主动 seal node-2

对 8210 节点执行 `vault operator seal`：

```bash
VAULT_ADDR=http://127.0.0.1:8210 vault operator seal
```

确认该节点已封印：

```bash
curl -sS http://127.0.0.1:8210/v1/sys/seal-status | jq '{sealed, initialized}'
```

`sealed` 应为 `true`。

## 3.3 等几秒，再次查询服务目录

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

## 3.4 重新 unseal 让节点回到 standby 池

把节点 8210 重新 unseal：

```bash
VAULT_ADDR=http://127.0.0.1:8210 vault operator unseal "$UNSEAL_KEY"
sleep 10

echo "=== unseal 之后的 standby 端点（应恢复 2 条）==="
dig @127.0.0.1 -p 8600 standby.vault.service.consul SRV +short
```

## 3.5 这一步的核心闭环

学员观察到：sealed 节点对客户端而言"自动隐身"——这是 Consul 健康检查与 Vault `service_registration` 协作的直接产物，无需任何客户端侧改造，也无需运维手工调整 Consul 的 service catalog。下一步把 `service_tags` / `service_meta` 两个字段加进配置文件，看 Vault 如何把自定义标签透传给 Consul。
