# 实验：Cubbyhole 引擎与 Token 隔离全流程

3.4 章节里我们梳理了 Cubbyhole 这个特殊的内置引擎：

- **默认挂载且生命周期被锁死**：不能 disable、不能 move、不能再次 enable
- **可见性绑定到 Token**：每个 Token 一个私有命名空间，root 也看不见别人的
- **Token 寿命即数据寿命**：Token 过期 / revoke 时 cubbyhole 同步销毁
- **Response Wrapping 的字面载体**：`cubbyhole/response` 路径 = wrap/unwrap 黑箱的内部实现

本实验在一个 Dev 模式 Vault 上把这四条全部亲手跑一遍。每一步都设计成**可以独立重入**，做错了重新跑就行。

实验环境会预先：

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 把 `VAULT_ADDR` / `VAULT_TOKEN` 持久化，所有终端都能直接用 `vault` 命令
- 安装 `jq`，方便解析 JSON 输出

不会预置任何 cubbyhole 数据——所有写入、token 创建、wrap/unwrap 都由你来做，确保你看到的隔离行为都是从 0 开始一步步演变出来的。
