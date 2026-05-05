# 第一步：盘点现状并启用机密引擎

先列出当前已经安装的策略。dev server 默认会有 `default` 和 `root`，它们是内置策略，后续不会在实验中删除。

```bash
vault policy list
```

再列出当前已经启用的机密引擎。注意输出里的 `Path` 才是后续策略和命令要使用的路径前缀，`Type` 只是机密引擎类型。

```bash
vault secrets list
```

启用一个教学用 KV v2 机密引擎。这里把类型 `kv` 挂载到自定义路径 `team-kv/`，并通过 `-version=2` 指定使用 KV v2。

```bash
vault secrets enable \
  -path=team-kv \
  -description="Team KV for policy and secrets lab" \
  -version=2 \
  kv
```

查看详细列表，确认 `team-kv/` 已经出现在挂载点列表中。`-detailed` 会显示更多运行信息，本实验先关注 `Path`、`Plugin`、`Accessor`、`Default TTL`、`Max TTL` 与 `Description`。

```bash
vault secrets list -detailed | grep -E 'Path|team-kv/'
```

写入一条教学机密，稍后用策略限制谁可以读取它。

```bash
vault kv put team-kv/app/config username="webapp" password="initial-password"
vault kv get team-kv/app/config
```

本步骤的重点是确认“机密引擎路径”是授权设计的基础。策略并不是写给 `kv` 这个类型，而是写给实际路径，例如后续会用到的 `team-kv/data/app/config`。
