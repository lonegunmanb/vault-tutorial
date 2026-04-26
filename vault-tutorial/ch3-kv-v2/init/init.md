# 实验：KV v2 版本控制、软删硬删与 Policy 路径

3.2 章节里我们梳理了 KV v2 的核心机制：

- **`data/` 与 `metadata/` 双层路径**——CLI 看不到，但 Policy 和 HTTP API 必须显式写
- **版本历史**：每次 `put` 产生新版本，旧版本可定向回读
- **删除三态**：`delete`（软）→ `undelete`（撤销）→ `destroy`（硬）→ `metadata delete`（连元数据一起清空）
- **CAS / max_versions / patch** 等并发与回收机制

本实验让你在一个 Dev 模式 Vault 上把这些行为亲手跑一遍，每一步都设计成**可以独立重入**，做错了重新来即可。

实验环境会预先：

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 把 `VAULT_ADDR` / `VAULT_TOKEN` 持久化，所有终端都能直接用 `vault` 命令
- 安装 `jq`，方便解析 JSON 输出

不会预置任何 KV 数据——所有挂载、写入、删除、Policy 都由你来做，确保你看到的版本号 / 元数据状态都是从 0 开始一步步演变出来的。
