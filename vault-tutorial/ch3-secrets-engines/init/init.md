# 实验：机密引擎挂载、生命周期与 Barrier View 隔离

3.1 章节里我们建立了机密引擎的心智模型——**路由 + 生命周期 + Barrier View 隔离**。本实验让你亲手在一个 Dev 模式的 Vault 上跑一遍：

- 在不同路径下挂载**多个同类型 KV 实例**，观察它们的 Accessor / UUID 完全不同——这就是 Barrier View 的物理证据
- 触发 Vault 对**路径大小写敏感**和**挂载点互为前缀**这两条硬规则的拒绝
- 演示 `vault secrets tune` 在线调参（数据零影响）和 `vault secrets disable` 销毁式卸载的不可逆性
- 对比两个独立 KV 实例的存储隔离，确认一个引擎写的数据**绝对不会**被另一个引擎看到

实验环境会预先：

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 把 `VAULT_ADDR` / `VAULT_TOKEN` 持久化，所有终端都能直接执行 `vault` 命令
- 安装 `jq` 以便解析 JSON 输出

每一步都是独立可重入的，做错了重来即可。
