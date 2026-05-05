# 第二步：`put` / `get` / `list` 基础操作

本步骤练习静态机密的基础读写与目录观察。所有命令都使用 `-mount=secret`，使挂载点和机密路径保持清晰分离。

## 2.1 写入第一版数据

```bash
vault kv put -mount=secret training/app username=app password=initial region=ap-southeast-1
```

读取这条机密：

```bash
vault kv get -mount=secret training/app
```

输出应包含 Metadata 和 Data。Metadata 中的 `version` 应为 `1`。

## 2.2 只读取一个字段

如果脚本只需要密码字段，可使用 `-field`：

```bash
vault kv get -mount=secret -field=password training/app
echo
```

这里额外执行 `echo`，是为了让终端换行。`-field` 输出本身不附带末尾换行。

## 2.3 写入第二版并读取历史版本

再次写入完整数据：

```bash
vault kv put -mount=secret training/app username=app password=rotated region=ap-southeast-1
```

读取最新版本：

```bash
vault kv get -mount=secret training/app
```

再读取第一版：

```bash
vault kv get -mount=secret -version=1 training/app
```

同一条 key 下现在存在两个版本。默认 `get` 返回最新版本，`-version=1` 返回指定历史版本。

## 2.4 列出目录

创建另一条训练数据：

```bash
vault kv put -mount=secret training/cache endpoint=redis ttl=24h
```

列出 `training/` 目录下的 key：

```bash
vault kv list -mount=secret training/
```

`list` 只返回 key 名称，不返回 `password`、`endpoint` 等字段值。路径名称本身可能暴露业务含义，因此生产环境不应把敏感信息写进 key 名称。

---

下一步将配置 key 级 metadata，并使用 CAS 与 `patch` 降低误覆盖风险。