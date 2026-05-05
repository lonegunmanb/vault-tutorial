# 实验：KV 专用命令

本实验围绕 `vault kv` 命令组展开。学员将使用真实 Vault dev server，依次验证 KV 专用命令相对于通用 CRUD 命令提供的便利：挂载点与机密路径分离、KV v2 版本读取、metadata 管理、CAS 写入保护、局部 patch、删除三态以及 rollback。

实验环境已预先准备：

- Vault dev server，root token 固定为 `root`
- 默认 `secret/` KV v2 挂载点
- `jq`，用于观察 JSON 输出
- 一个空的 `/root` 工作目录，可安全创建临时 JSON 文件

建议按步骤顺序执行。所有数据都写入训练路径，刷新实验环境即可恢复初始状态。