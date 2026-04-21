# 实验：Shamir 阈值深观察、Rotate vs Rekey 实战

第 1 章 `what-is-vault` 的实验里，你已经亲手走过一次完整的"init + 三轮 Shamir 解封 + 主动 seal + 重新解封 + Barrier 密文观察"。本实验**不再重复这些基础流程**，环境会自动帮你完成下列前置工作：

- 用 HCL 配置文件启动一个 Vault 服务器（文件存储后端 + Shamir 5/3）
- 执行 `vault operator init` 并把 5 份分片 + 初始 Root Token 保存到 `/root/workspace/`
- 用 3 份分片完成解封
- 启用 KV v2 引擎并写入 `secret/seal-demo` 与 `secret/before-rotate` 两条机密

你一打开终端就直接面对一台**已经在跑、Sealed=false、装着真实数据**的 Vault。本实验聚焦在三件 `what-is-vault` 没覆盖的事情上：

1. **Shamir 阈值机制的深入观察**：`Unseal Nonce` 字段、任意 K 份分片的等价性、少于 K 份时 Vault 的"卡住"状态
2. **`vault operator rotate`**：DEK（数据加密密钥）在线轮转，验证 keyring 兼容
3. **`vault operator rekey`**：重新生成 Unseal Key 并把 5/3 改成 7/4，亲眼验证老分片彻底失效

最后会用 `vault token revoke` 吊销初始 Root Token，对应生产环境的标准收尾动作。
