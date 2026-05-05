# 第一步：`-mount` 写法与 `enable-versioning`

本步骤先确认 `vault kv` 推荐的 `-mount` 写法，然后创建一个 KV v1 挂载点，并使用 `enable-versioning` 将它切换为版本化 KV。

## 1.1 查看默认 KV v2 挂载点

Dev 模式下默认存在 `secret/`。先查看它的版本配置：

```bash
vault secrets list -detailed | grep -E "Path|^secret/"
```

在输出中，`Type` 列通常是 `kv`，`Options` 列包含 `version:2`。这表示挂载点类型是 KV，引擎版本是 v2。

## 1.2 使用 `-mount` 写入和读取

执行以下命令：

```bash
vault kv put -mount=secret training/mount-demo value=from-mount-syntax
vault kv get -mount=secret training/mount-demo
```

观察输出中的 Secret Path。虽然命令中没有写 `data/`，KV v2 的实际路径仍会显示为 `secret/data/training/mount-demo`。

## 1.3 创建一个 KV v1 挂载点

为了演示 `enable-versioning`，创建一个新的非版本化 KV 挂载点：

```bash
vault secrets enable -path=legacy kv
vault kv put -mount=legacy app name=legacy-api password=legacy-pass
vault kv get -mount=legacy app
```

KV v1 的 `get` 输出没有 Metadata 块，因为它没有版本信息。

## 1.4 启用版本控制

对 `legacy/` 挂载点启用版本控制：

```bash
vault kv enable-versioning legacy
vault secrets list -detailed | grep -E "Path|^legacy/"
```

再次读取同一条数据：

```bash
vault kv get -mount=legacy app
vault kv metadata get -mount=legacy app
```

现在输出中应出现 Metadata 与版本信息。后续步骤统一使用默认的 `secret/` KV v2 挂载点。

---

进入下一步后，将继续练习 `put`、`get` 和 `list`。