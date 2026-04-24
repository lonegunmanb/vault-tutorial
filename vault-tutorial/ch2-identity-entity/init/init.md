# Entity / Alias / Group 的归并与策略叠加

阅读 [2.5 章节文档](../ch2-identity-entity) 之后，本实验把 Identity
文档里五个关键设计点亲手验证一遍：

- 任何非 token 的 auth method 登录都会**自动**生成 entity + alias
- 同一种 auth method 在两个不同 mount 上的 alias **不会**自动合并
- 手工合并后，多种登录方式得到的 token 共享同一个 `entity_id`
- Entity policy 在请求时动态求值——挂上立刻生效、摘掉立刻失能，**不需要重登**
- Identity Group 让策略沿组关系（含子组）传递

后台脚本会启动 Vault dev 模式（root token = `root`），并安装 `jq`
方便后续 JSON 解析。
