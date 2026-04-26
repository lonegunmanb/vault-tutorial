# 第一步：挂载多个 KV 实例，观察 Accessor 与 UUID

3.1 章节里讲过一句话：**"每次启用一个引擎，Vault 都会分配一个新的 UUID 作为该引擎的存储根目录。"** 这一步亲手验证。

## 1.1 查看 Vault 启动时的内置挂载点

```bash
vault secrets list -detailed
```

注意几列：

- `Path`：API 路径前缀
- `Type`：引擎类型（kv、cubbyhole、system、identity 等）
- `Accessor`：挂载实例的不可变唯一标识
- `UUID`：底层存储的根目录 UUID（每个 Accessor 有自己独立的子树）

`secret/` 是 Dev 模式默认挂载的 KV v2，`cubbyhole/`、`sys/`、`identity/` 是内置引擎（**不能 disable**）。

## 1.2 自定义路径挂载第一个 KV 实例：team-dev-kv/

```bash
vault secrets enable -path=team-dev-kv -version=2 kv
```

输出应该类似：

```
Success! Enabled the kv-v2 secrets engine at: team-dev-kv/
```

写入一些数据：

```bash
vault kv put team-dev-kv/db host=db.dev.internal password=dev-secret
vault kv put team-dev-kv/api token=ak_dev_xxxxx
```

## 1.3 挂载第二个 **同类型** KV 实例：team-prod-kv/

```bash
vault secrets enable -path=team-prod-kv -version=2 kv
vault kv put team-prod-kv/db host=db.prod.internal password=PROD-SECRET
```

## 1.4 对比两个实例的 Accessor 与 UUID

```bash
vault secrets list -format=json \
  | jq '{ "team-dev-kv":  ."team-dev-kv/"  | {accessor, uuid, type},
          "team-prod-kv": ."team-prod-kv/" | {accessor, uuid, type} }'
```

输出会类似：

```json
{
  "team-dev-kv": {
    "accessor": "kv_xxxxxxxx",
    "uuid":     "aaaaaaaa-1111-2222-...",
    "type":     "kv"
  },
  "team-prod-kv": {
    "accessor": "kv_yyyyyyyy",
    "uuid":     "bbbbbbbb-3333-4444-...",
    "type":     "kv"
  }
}
```

**关键观察**：

- `type` 完全相同（都是 `kv`）
- `accessor` 与 `uuid` **完全不同**

这就是 Vault 文档里那句话的物理证据：

> When a secrets engine is enabled, **a random UUID is generated**.
> This becomes the data root for that engine.

两个 KV 实例在底层存储里各自拥有以自己 UUID 为根的"chroot"——下一步你将验证它们的数据完全隔离。

## 1.5 验证两个实例数据互不可见

```bash
echo "=== team-dev-kv 下的 keys ==="
vault kv list team-dev-kv/

echo ""
echo "=== team-prod-kv 下的 keys ==="
vault kv list team-prod-kv/

echo ""
echo "=== 同名 key 'db' 的内容是分别独立的 ==="
echo "--- team-dev-kv/db ---"
vault kv get -field=password team-dev-kv/db
echo "--- team-prod-kv/db ---"
vault kv get -field=password team-prod-kv/db
```

两条 `db` 数据各自存在自己的 UUID 子树里，**就算 key 名字一模一样，也是两份完全独立的数据**——这就是 Vault 多租户隔离的最常用模式。
