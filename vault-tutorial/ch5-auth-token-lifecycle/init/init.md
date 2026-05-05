# 实验：login / auth / token 认证与生命周期命令实战

本实验围绕三组容易混淆的 CLI 命令展开：`vault login`、`vault auth ...` 与 `vault token ...`。

实验环境已预先准备：

- Vault dev server，root token 固定为 `root`
- `secret/` KV v2 引擎中的 `app/config` 测试数据
- `app-read` 策略，用于演示 token capability 与实际读权限
- `jq`，用于解析 JSON 输出

你将依次完成认证方法挂载、登录、token 创建、权限诊断、续期、撤销和禁用认证方法。建议按步骤顺序执行；如果重复执行导致对象已存在，可刷新实验环境恢复初始状态。
