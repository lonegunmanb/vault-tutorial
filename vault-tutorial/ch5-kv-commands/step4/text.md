# 第四步：删除三态

本步骤使用一条独立的 `training/delete-demo` 机密，体验 `delete`、`undelete`、`destroy` 和 `metadata delete` 的差异。

## 4.1 准备多版本数据

```bash
vault kv put -mount=secret training/delete-demo value=v1
vault kv put -mount=secret training/delete-demo value=v2
vault kv put -mount=secret training/delete-demo value=v3
vault kv metadata get -mount=secret training/delete-demo
```

当前版本应为第 3 版。

## 4.2 软删除最新版本

```bash
vault kv delete -mount=secret training/delete-demo
vault kv get -mount=secret training/delete-demo
```

`get` 仍会显示第 3 版的 Metadata，并在 `deletion_time` 中标出删除时间；但不再显示 Data 区块或 `value`，因为最新版本已经被标记为删除。

恢复第 3 版：

```bash
vault kv undelete -mount=secret -versions=3 training/delete-demo
vault kv get -mount=secret training/delete-demo
```

## 4.3 软删除并恢复指定版本

```bash
vault kv delete -mount=secret -versions=2 training/delete-demo
vault kv get -mount=secret -version=2 training/delete-demo
```

此时读取第 2 版应只看到带删除时间的 Metadata，不会看到 Data 中的 `value`。再执行恢复：

```bash
vault kv undelete -mount=secret -versions=2 training/delete-demo
vault kv get -mount=secret -version=2 training/delete-demo
```

## 4.4 永久销毁指定版本

```bash
vault kv destroy -mount=secret -versions=1 training/delete-demo
vault kv metadata get -mount=secret training/delete-demo
```

在 metadata 中，第 1 版的 `destroyed` 应显示为 `true`。这表示该版本数据已经被永久移除，不能再通过 `undelete` 恢复。

## 4.5 删除所有版本和 metadata

```bash
vault kv metadata delete -mount=secret training/delete-demo
vault kv metadata get -mount=secret training/delete-demo
```

最后一条命令预计返回错误，因为这条 key 的所有版本和 metadata 已经被删除。

---

下一步将使用 `rollback`，观察历史版本如何成为新的当前版本。