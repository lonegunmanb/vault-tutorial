# 第四步：Barrier View 的物理隔离证据

第一步你已经看到两个 KV 实例的 `accessor` 和 `uuid` 完全不同——这一步从**正反两个方向**进一步验证这个隔离是**物理级**的，而不只是命名上的隔离。

## 4.1 准备两个独立的 KV 实例

第三步把 `team-dev-kv/` 重新挂载了一次，但里面还是空的。`team-prod-kv/` 应该还有第一步写入的数据。先把两个实例都填上数据：

```bash
vault kv put team-dev-kv/db  host=db.dev.internal  password=dev-secret-NEW
vault kv put team-dev-kv/api token=ak_dev_re_created
```

`team-prod-kv/db` 第一步已经写过 `password=PROD-SECRET`，留着不动。

接下来为了 4.4 能看到 "disable 前 → 重新 enable 后" 的 UUID 对比，
先把 `team-prod-kv/` 当前的 Accessor / UUID 存到临时文件：

```bash
vault secrets list -format=json \
  | jq '."team-prod-kv/" | {accessor, uuid}' \
  | tee /tmp/team-prod-kv.before.json
```

输出会类似：

```json
{
  "accessor": "kv_yyyyyyyy",
  "uuid": "bbbbbbbb-3333-4444-..."
}
```

记住这个 UUID（4.4 要拿它跟 disable+重新 enable 后的新值对比）。

## 4.2 同名 key 的内容彼此独立

```bash
echo "team-dev-kv/db.password  = $(vault kv get -field=password team-dev-kv/db)"
echo "team-prod-kv/db.password = $(vault kv get -field=password team-prod-kv/db)"
```

输出：

```
team-dev-kv/db.password  = dev-secret-NEW
team-prod-kv/db.password = PROD-SECRET
```

key 完全同名（都叫 `db`），但落在不同的 UUID 子树，所以是两条互不相干的数据。

## 4.3 一个引擎被 disable，**只**影响自己的子树

```bash
echo "=== disable team-prod-kv/（只动它一个）==="
vault secrets disable team-prod-kv/

echo ""
echo "=== team-prod-kv/db 已经不存在 ==="
vault kv get team-prod-kv/db 2>&1 | tail -3

echo ""
echo "=== team-dev-kv/db 完全不受影响 ==="
vault kv get -field=password team-dev-kv/db
```

**关键观察**：`team-dev-kv/db` 没有任何变化。这就是 Barrier View 的隔离保证：

> Vault 的存储层**不支持相对访问（如 `../`）**，因此一个引擎实例在 Go API 层根本拿不到指向"其他 UUID 子树"的存储句柄。
> 这是 Vault 多租户安全的物理底层保证——即便某个第三方插件存在 bug 或恶意代码，它也无法越界读到其他引擎的数据。

## 4.4 路径相同 ≠ 引擎相同

最后做一个有意思的对比——把 `team-prod-kv/` 重新 enable 一次：

```bash
vault secrets enable -path=team-prod-kv -version=2 kv
```

拿出新 UUID，和 4.1 保存的旧 UUID 拼在一起看：

```bash
vault secrets list -format=json \
  | jq '."team-prod-kv/" | {accessor, uuid}' \
  > /tmp/team-prod-kv.after.json

echo "=== disable 之前（4.1 记录的）==="
cat /tmp/team-prod-kv.before.json
echo
echo "=== 重新 enable 之后（同名路径、全新实例）==="
cat /tmp/team-prod-kv.after.json
```

两份 JSON 会明显不同：

```json
=== disable 之前 ===
{
  "accessor": "kv_yyyyyyyy",
  "uuid":     "bbbbbbbb-3333-4444-..."
}
=== 重新 enable 之后 ===
{
  "accessor": "kv_zzzzzzzz",
  "uuid":     "cccccccc-5555-6666-..."
}
```

**关键观察**：路径一模一样（都是 `team-prod-kv/`），但 `accessor` 与
`uuid` 都是**全新**的——这是一个完全独立的引擎实例，只是恰好被挂在了
同名路径上。之前的 `team-prod-kv/db` 数据在第三步原理下**永远找不回
来**：

```bash
vault kv list team-prod-kv/ 2>&1 | tail -3
```

输出会是 `No value found at team-prod-kv/metadata`，因为新 UUID 子树是空的。

> **教学要点**：在 Vault 中谈论"一个引擎"时，实际指向的是"路径前缀 → Accessor/UUID 这个绑定"。**路径只是路由表里的 key，UUID 才是引擎实例的身份**。

## 4.5 速查：用 -detailed 看清一切

最后一条命令把所有挂载实例的物理身份打出来：

```bash
vault secrets list -detailed | column -t | head -20
```

`Accessor` 和 `UUID` 这两列就是 Barrier View 的索引。
- 同一个 Accessor → 同一个引擎实例（即便用 `vault secrets move` 改了路径）
- 不同的 UUID → 物理隔离的两块"chroot"——绝对不会互相看到对方的数据

至此，3.1 章节里所有关键设计都已经过你的亲手验证。
