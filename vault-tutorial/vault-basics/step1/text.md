# 第一步：启动 Vault Dev 服务器

Vault Dev 服务器已在后台启动。Dev 模式适合学习和开发，它：

- 自动初始化并解封（Unseal）
- 使用内存存储（重启后数据丢失）
- Root Token 为 `root`
- 监听地址为 `http://127.0.0.1:8200`

验证 Vault 状态：

```bash
vault status
```

你应该看到 `Sealed: false`，说明 Vault 已就绪。

查看 Vault 版本：

```bash
vault version
```
