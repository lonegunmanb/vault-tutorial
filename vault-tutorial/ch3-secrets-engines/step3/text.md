# 第三步：tune 在线调参 vs disable 的销毁式卸载

3.1 章节里说生命周期四件套是 `enable / disable / move / tune`。`move` 在 5.7 章详讲，本步专门对比 `tune`（数据零影响）和 `disable`（不可逆销毁）的差异。

## 3.1 查看引擎当前的 tune 配置

继续用第一步挂上的 `team-dev-kv/`：

```bash
vault secrets list -detailed -format=json | jq '
  ."team-dev-kv/"
  | { default_lease_ttl: .config.default_lease_ttl,
      max_lease_ttl:     .config.max_lease_ttl,
      options:           .options }
'
```

输出大致是：

```json
{
  "default_lease_ttl": 0,
  "max_lease_ttl":     0,
  "options": {
    "version": "2"
  }
}
```

两个 TTL 字段的值是 **`0`**——这是 Vault 表达"该挂载点没有自己
设置 TTL，沿用 Vault 全局默认值"的方式。`options.version: "2"` 是上
一步 `-version=2` 的真正落点（也印证了 step1 里那条提示：区分
KV v1/v2 不是看 `Type`，而是看这里的 `options.version`）。

> **坑点提醒**：`vault secrets list -detailed -format=json` 返回的**顶层**
> 也有一对同名字段 `default_lease_ttl` / `max_lease_ttl`，但那两个顶
> 层字段**始终是 `null`**——真正的 TTL 配置被返回在 `.config.*`
> 下面，只有表格形式的输出才会合成填到顶层那两列。
>
> 同样的命令换成默认表格形式
> `vault secrets list -detailed | grep team-dev-kv`，TTL 这两列会显示为
> 字符串 `system`——同样是"沿用全局默认"的含义。

## 3.2 用 `tune` 修改 TTL

```bash
vault secrets tune \
  -default-lease-ttl=1h \
  -max-lease-ttl=24h \
  team-dev-kv/
```

```bash
vault secrets list -detailed -format=json | jq '
  ."team-dev-kv/".config
  | {default_lease_ttl, max_lease_ttl}
'
```

```json
{
  "default_lease_ttl": 3600,
  "max_lease_ttl":     86400
}
```

之前的 `0` 现在变成了具体的秒数（1h = 3600，24h = 86400），说明这
个挂载点已经覆盖了全局默认。表格形式同位置现在也会从 `system`
变成 `1h` / `24h`。

**关键观察**：刚才写入的 `team-dev-kv/db` 与 `team-dev-kv/api` 数据完全不受影响：

```bash
vault kv get -field=password team-dev-kv/db
vault kv get -field=token    team-dev-kv/api
```

`tune` 改的是**引擎运行参数**（TTL、可见 header、密封 wrap TTL 等），不动数据。可以反复执行任意次。

> **典型用法**：`tune` 是生产里最常用的"温和"调整。比如发现某个 KV 引擎下产生的 lease 默认时间过长，直接 `vault secrets tune -default-lease-ttl=10m kv/` 即可，无需任何停机。

## 3.3 用 `disable` 销毁一个引擎，看清"不可逆"

先确认 `team-dev-kv/` 现在还有数据：

```bash
echo "=== disable 之前 ==="
vault kv list team-dev-kv/
```

输出：

```
Keys
----
api
db
```

**销毁式卸载**：

```bash
vault secrets disable team-dev-kv/
```

输出：

```
Success! Disabled the secrets engine (if it existed) at: team-dev-kv/
```

verify 旧路径已不存在：

```bash
echo "=== disable 之后，旧路径再也读不到 ==="
vault kv list team-dev-kv/ 2>&1 | tail -3
vault kv get  team-dev-kv/db 2>&1 | tail -3
```

会看到 `no secrets engine mounted at this path` 之类的错误。

## 3.4 验证"重新 enable 同名路径，得到的是空引擎 + 新 UUID"

这是 3.1 章节里那条"`disable` 删除的就是该引擎的 UUID 子树"原理的关键证据——**重启不能恢复数据**：

```bash
# 在同一个路径再次 enable
vault secrets enable -path=team-dev-kv -version=2 kv

# 看新 UUID
vault secrets list -format=json | jq '."team-dev-kv/" | {accessor, uuid}'

# 看数据是不是空的
vault kv list team-dev-kv/ 2>&1 | tail -3
```

**关键观察**：

- `accessor` 与 `uuid` 都是**全新**的（与第一步记录的不同——它是一个全新的引擎实例）
- `kv list` 报 `No value found at team-dev-kv/metadata` 之类的错误（因为新 UUID 子树里什么都没有）
- 之前写的 `db` 和 `api` 数据**永远找不回来**

> **生产警示**：任何一次 `vault secrets disable` 都是**不可逆**的。把它当作 `DROP DATABASE`，不是 `pause`。需要换路径请用 5.7 的 `vault secrets move`，不要"先 disable 再 enable"。

## 3.5 验证内置引擎不能被 disable

`sys/`、`cubbyhole/`、`identity/` 是 Vault 内置引擎，提供 Vault 自身的运行能力，不能 disable：

```bash
vault secrets disable sys/       2>&1 | tail -3
vault secrets disable cubbyhole/ 2>&1 | tail -3
vault secrets disable identity/  2>&1 | tail -3
```

每条都会被 Vault 拒绝。
