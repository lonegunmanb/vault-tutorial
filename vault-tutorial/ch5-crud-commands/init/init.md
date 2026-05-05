# 实验：核心 CRUD 交互指令

本实验会把 `vault read`、`vault write`、`vault delete`、`vault list`、`vault patch` 放到同一个 Vault dev server 里练一遍。你会看到：这些命令本身很薄，真正的语义来自路径后面的后端引擎。

实验环境已预先准备：

- Vault dev server，root token 固定为 `root`
- `transit/` 机密引擎，用于演示 `write -force` 与安全删除
- `pki/` 机密引擎和一个 `example` role，用于演示 `patch`
- 一个 Identity Entity，用于演示 `list`
- `jq`，用于观察 JSON 输出

建议按步骤顺序执行。每一步都可以反复跑；如果你把某个对象删掉了，刷新实验环境即可恢复。
