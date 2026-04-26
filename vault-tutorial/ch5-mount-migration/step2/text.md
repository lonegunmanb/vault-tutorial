# 第二步：机密引擎的路径迁移：vault secrets move

`vault secrets move` 对应底层 API `POST /sys/remount`。它把一个机密引擎（包括所有数据、配置、角色）从一个路径原子迁移到另一个路径。

## 2.1 迁移前：记录 Accessor

先记下 `legacy-kv/` 的 Accessor，等下用来验证"是同一个引擎搬了家，不是新建了一个"：

```bash
BEFORE_ACC=$(vault secrets list -format=json | jq -r '.["legacy-kv/"].accessor')
echo "迁移前 Accessor = $BEFORE_ACC"
```

## 2.2 执行迁移：legacy-kv/ → archive/

`vault secrets move` 默认输出里包含一个 `migration_id`（迁移作业的
ID）。我们用 `-format=json` 把它直接捕获到 shell 变量里，**关键是这
一步只能执行一次**——再 move 一次同一个旧路径就会报"路径不存在"。

```bash
MIG_ID=$(vault secrets move -format=json legacy-kv/ archive/ \
  | jq -r .migration_id)
echo "migration_id = $MIG_ID"
```

输出大致是：

```
Key             Value
---             -----
migration_id    abcdef12-3456-7890-...
```

迁移是**异步**执行的，但对小引擎来说几乎瞬间完成。

## 2.3 查询迁移状态

用刚才捕获的 `MIG_ID` 查状态：

```bash
vault read sys/remount/status/$MIG_ID
```

字段 `migration_status` 应当是 `success`。

> 实际上对 dev 模式下的小数据集，迁移在你按回车之前就已经完成了。
> `sys/remount/status/:migration_id` 主要用于生产环境中几百 GB 级别
> 大引擎迁移的进度监控。

## 2.4 验证：旧路径已不存在

```bash
echo "=== 尝试从旧路径读取（应该报错）==="
vault kv get legacy-kv/old-service 2>&1 | tail -3
```

输出会包含 `no secrets engine mounted at this path` 之类的错误——旧路径已经彻底不存在了。

## 2.5 验证：新路径数据完好

```bash
echo "=== 从新路径读取 ==="
vault kv get -format=json archive/old-service | jq .data.data
```

```json
{
  "token": "tok_legacy_12345"
}
```

数据完整搬过来了。

## 2.6 验证：Accessor 没有变

这是证明"搬家而非新建"的关键：

```bash
AFTER_ACC=$(vault secrets list -format=json | jq -r '.["archive/"].accessor')
echo "迁移后 Accessor = $AFTER_ACC"

if [ "$BEFORE_ACC" = "$AFTER_ACC" ]; then
  echo "✅ Accessor 相同——是同一个引擎换了路径，不是新建"
else
  echo "❌ Accessor 不同（不应该出现）"
fi
```

Accessor 不变意味着：

- 底层存储中的数据**零拷贝**——Vault 只是修改了内部路由表
- 引擎下的所有配置（tune 参数、TTL 设置等）原封不动保留
- 如果是 Database 引擎，挂载的 role、connection 配置也跟着走

## 2.7 查看迁移后的引擎列表

```bash
vault secrets list -format=table
```

你会看到 `archive/` 出现在列表里，`legacy-kv/` 已经消失。

## 2.8 迁移限制：不能跨类型、不能覆盖

几个会被 Vault 拒绝的操作：

```bash
echo "=== 尝试迁移到一个已存在的路径（应该报错）==="
vault secrets move archive/ secret/ 2>&1 | tail -3
```

已经有引擎挂在 `secret/` 上，所以 Vault 拒绝覆盖——你需要先 `vault secrets disable` 目标路径（当然这会销毁目标路径的数据），或者选一个空路径。

> **关键限制**：Mount Migration 只能迁移同一类型的引擎到新路径，不能借此把 KV v1 变成 KV v2，也不能把 KV 引擎变成 Transit 引擎。它是纯粹的"路径重命名"操作。
