# 第五步：`rollback` 把历史版本恢复成新版本

`rollback` 的作用不是让版本号倒退，而是把某个旧版本的数据复制成一个新的当前版本。本步骤将通过 `training/history` 观察这一点。

## 5.1 准备三版数据

```bash
vault kv put -mount=secret training/history color=red
vault kv put -mount=secret training/history color=blue
vault kv put -mount=secret training/history color=green
vault kv get -mount=secret training/history
```

当前版本应为第 3 版，字段 `color` 的值应为 `green`。

## 5.2 查看历史版本

```bash
vault kv get -mount=secret -version=1 training/history
vault kv get -mount=secret -version=2 training/history
vault kv metadata get -mount=secret training/history
```

确认第 1 版是 `red`，第 2 版是 `blue`，第 3 版是 `green`。

## 5.3 回滚到第 1 版

```bash
vault kv rollback -mount=secret -version=1 training/history
vault kv get -mount=secret training/history
vault kv metadata get -mount=secret training/history
```

回滚后，当前值应变为 `red`，但当前版本号应是第 4 版，而不是第 1 版。版本历史会继续向前记录本次回滚结果。

## 5.4 用 JSON 输出观察当前数据和 metadata

```bash
vault kv get -mount=secret -format=json training/history | jq '{data: .data.data, metadata: .data.metadata}'
```

这条命令把业务数据和版本 metadata 分开显示，有助于脚本或应用理解 KV v2 的返回结构。

---

至此，KV 专用命令的核心操作已经全部完成。