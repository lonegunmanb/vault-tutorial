# 实验：Identity 机密引擎与 OIDC Provider 全流程

3.6 章节里我们梳理了 `identity/` 这个特殊的内置引擎：

- 和 `cubbyhole/` 一样**默认挂载、不可禁用、不可迁移、不可二次挂载**
- 通过子路径 `identity/entity` / `entity-alias` / `group` 提供 Vault
  自己的身份对象 CRUD
- 通过 `identity/oidc/key` + `identity/oidc/role` + `identity/oidc/token`
  让 Vault 变成**符合 OIDC 规范的 JWT 签发机**
- 通过 `identity/oidc/provider` + `client` + `assignment` 让 Vault
  反向变成下游应用的 **OIDC Identity Provider**
- 1.19+ 提供 `force-identity-deduplication` 激活机制清理历史重复身份

本实验在一个 Dev 模式 Vault（1.19.2，含 dedup 能力）上把这些要点全
部亲手跑一遍。每一步都设计成**可以独立重入**，做错了重新跑就行。

实验环境会预先：

- 安装 Vault 1.19.2 并以 Dev 模式启动（root token = `root`）
- 把 `VAULT_ADDR` / `VAULT_TOKEN` 持久化，所有终端都能直接用 `vault`
- 安装 `jq`，方便解析 JSON 输出

不会预先创建任何 Entity / Group / OIDC 配置——所有对象都由你来建，
确保看到的归并 / 签发 / 登录行为都是从 0 开始一步步演变出来的。
