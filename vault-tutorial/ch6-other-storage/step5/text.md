# 第五步：DynamoDB 后端 — 用 LocalStack 模拟 AWS DynamoDB + Vault 自动建表

[6.5 节 §4](/ch6-other-storage) 已经说明：DynamoDB 后端**支持高可用**（但受节点时钟漂移影响）、由社区维护，并且**与 PostgreSQL 后端最显著的差异之一是：Vault 会在初始化时自动创建 DynamoDB 表，无需手工 `CREATE TABLE`**。本步把这一行为在本地 LocalStack 上跑出来，让学员亲眼看到 Vault 直接操作 DynamoDB 的全过程。

> 如果上一步的 localstack 容器仍在运行，本步无需重启。可以用 `docker ps | grep localstack` 确认；若没在跑，再次执行 `./start-localstack.sh`。

## 5.1 确认 LocalStack 上的 DynamoDB 服务可用

```bash
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services.dynamodb'
```

应输出 `"available"`。

确认 LocalStack 当前**没有任何 DynamoDB 表**——这样接下来 Vault 自动建表的行为就更直观：

```bash
awslocal dynamodb list-tables
```

应输出 `{"TableNames": []}`。

## 5.2 查看预置配置文件

```bash
cat /root/vault-dynamodb.hcl
```

关注其中：

```hcl
storage "dynamodb" {
  ha_enabled = "true"
  access_key = "test"
  secret_key = "test"
  region     = "us-east-1"
  endpoint   = "http://127.0.0.1:4566"
  table      = "vault-data"
}
```

要点：

- `endpoint = "http://127.0.0.1:4566"`：DynamoDB API 的替代端点，对应正文 §4.2 的 `endpoint` 参数。
- `ha_enabled = "true"`：开启 DynamoDB 后端的高可用模式。**注意 §4.1 给出的工程警告——DynamoDB 锁的会话生命周期依赖节点本机时间，多节点显著时钟漂移会引发锁竞争问题**；本步只起一个 Vault 进程，看不出该问题，但选型时必须铭记。
- 没有 `dynamodb_allow_updates`：因此即使后续修改 `read_capacity` 等参数，Vault 也不会去改已有表。

## 5.3 启动 Vault 并初始化 — Vault 会自动建表

```bash
./start-vault.sh dynamodb
sleep 5
vault status || true
```

立刻回头看 LocalStack 上的 DynamoDB 表列表：

```bash
awslocal dynamodb list-tables
```

应当已经多出一张 `vault-data` 表——这就是 Vault 启动时**自动创建**的结果。看一下表结构是否符合 §4.3 给出的官方 schema：

```bash
awslocal dynamodb describe-table --table-name vault-data \
  --query 'Table.{KeySchema: KeySchema, AttributeDefinitions: AttributeDefinitions, BillingMode: BillingModeSummary.BillingMode, ProvisionedThroughput: ProvisionedThroughput}'
```

输出应为：**主分区键名 `Path`、类型字符串（`S`）；主排序键名 `Key`、类型字符串（`S`）**——与 6.5 节正文 §4.3 的描述完全一致。`ProvisionedThroughput` 中的 `ReadCapacityUnits` 与 `WriteCapacityUnits` 均为 `5`，对应正文 §4.2 列出的默认值；这本身就隐含了表是按 `PROVISIONED` 模式建出来的。

> 这里的 `BillingMode` 字段在 LocalStack 上会返回 `null`——LocalStack 没有实现 `BillingModeSummary` 的填充，但表的实际 billing 模式与真实 DynamoDB 一致（默认 `PROVISIONED`）。在真实 AWS 上同一条命令会返回 `"BillingMode": "PROVISIONED"`。

继续完成 Vault 初始化：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-dynamodb.json

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-dynamodb.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-dynamodb.json)
```

> **HA 选举有几秒延迟**：unseal 完成后，DynamoDB 后端要在 `vault-data` 表里抢一行锁才能把本节点切成 `active`，这一步在 LocalStack 上通常需要 5–15 秒。如果不等就直接调 `secrets enable`，会撞上 `local node not active but active cluster node not found` 的 500。等到 HA Mode 切成 `active` 再往下做：
>
> ```bash
> for i in $(seq 1 30); do
>   mode=$(vault status -format=json 2>/dev/null | jq -r '.ha_mode')
>   if [ "$mode" = "active" ]; then
>     echo "active in ${i}s"; break
>   fi
>   sleep 1
> done
> vault status | grep -E 'HA Mode|Active Node Address'
> ```
>
> 应当看到 `HA Mode active`、`Active Node Address http://127.0.0.1:8200`。

确认本节点已经是 active 之后再写入：

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/demo storage=dynamodb note="written-via-dynamodb-backend"
vault kv get secret/demo
```

## 5.4 直接到 DynamoDB 表里观察密文行

`scan` 整张表（条目数会有几十甚至上百，先取前 10 条看结构）：

```bash
awslocal dynamodb scan --table-name vault-data --max-items 10 \
  --query 'Items[].{Path: Path.S, Key: Key.S, value_bytes: Value.B}' \
  --output table
```

每一行都包含 `Path`（路径前缀）、`Key`（条目名）、`Value`（base64 编码后的密文字节）三列；`value_bytes` 列展示的全是 base64 后的乱码——**DynamoDB 表里能看到的只是密文，没有 unseal key 即使拿到表的完整副本也无法还原任何机密内容**。这是 step3（PostgreSQL）和 step4（S3）已经反复验证过的同一个事实，只是物化形式从"行" / "对象"换成了"DynamoDB item"。

## 5.5 重启 Vault 进程，确认 DynamoDB 后端持久化生效

```bash
pkill -f 'vault server'
sleep 2
./start-vault.sh dynamodb
sleep 5

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-dynamodb.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-dynamodb.json)

# 同样要等 HA 选举完成，否则 vault kv get 会撞上 "local node not active"
for i in $(seq 1 30); do
  mode=$(vault status -format=json 2>/dev/null | jq -r '.ha_mode')
  [ "$mode" = "active" ] && { echo "active in ${i}s"; break; }
  sleep 1
done

vault kv get secret/demo
```

数据仍然能读出来。这一步与 step3、step4 一样验证了"持久化后端的最小验收"，但本步还**额外**演示了 Vault 自动建表的能力——这是 DynamoDB 后端区别于 PostgreSQL 后端最直观的运维差异。
