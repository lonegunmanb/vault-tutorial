# 第三步：`metadata`、CAS 与 `patch`

本步骤查看版本 metadata，设置 key 级规则，然后用 CAS 和 `patch` 观察 KV v2 的防误覆盖机制。

## 3.1 查看 metadata

```bash
vault kv metadata get -mount=secret training/app
```

重点观察以下字段：

- `current_version`：当前最新版本号
- `cas_required`：写入时是否强制要求 CAS
- `max_versions`：该 key 最多保留多少个版本
- 每个 `Version` 块中的 `deletion_time` 与 `destroyed`

## 3.2 设置 key 级 metadata

执行以下命令，将 `training/app` 设置为最多保留 5 个版本，并要求后续写入必须携带 CAS：

```bash
vault kv metadata put -mount=secret \
  -max-versions=5 \
  -cas-required=true \
  -custom-metadata=owner=training \
  -custom-metadata=service=payments \
  training/app
```

再次查看 metadata：

```bash
vault kv metadata get -mount=secret training/app
```

应能看到 `cas_required` 变为 `true`，并且 metadata 中包含自定义信息。

## 3.3 观察缺少 CAS 时的失败

现在尝试直接写入第三版：

```bash
vault kv put -mount=secret training/app username=app password=third region=ap-southeast-1
```

这条命令预计会失败，因为该 key 已要求写入时提供 CAS。失败是本步骤的预期结果。

## 3.4 使用正确版本号写入

当前版本号仍是第 2 版，因此使用 `-cas=2`：

```bash
vault kv put -mount=secret -cas=2 training/app username=app password=third region=ap-southeast-1
vault kv get -mount=secret training/app
```

写入成功后，当前版本应变为第 3 版。

## 3.5 使用 `patch` 合并少量字段

只增加一个字段，不重写所有字段：

```bash
vault kv patch -mount=secret -cas=3 training/app rotated_by=student
vault kv get -mount=secret training/app
```

输出中应保留 `username`、`password`、`region`，并新增 `rotated_by`。当前版本应变为第 4 版。

---

下一步将对另一条训练 key 演示删除三态，避免破坏本步骤的 CAS 示例。