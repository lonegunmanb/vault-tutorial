# 第四步：观察 Barrier 加密效果

理解 Vault 最关键的一句话：**存储后端永远是不可信的。** 任何写入存储后端的数据都先经过 Barrier 加密层（AES-GCM 256），即使存储设备被偷走也无法泄密。

我们刚刚把 `secret/hello = world: "from raft storage"` 写入了 Vault。现在直接挖开 Raft 存储目录看看。

## 4.1 查看 Raft 存储目录结构

```bash
ls -lah /opt/vault/data/
ls -lah /opt/vault/data/raft/
```

你会看到 BoltDB 的物理文件 `vault.db`（Raft 把所有状态都存在 BoltDB 里）、Snapshots 目录等。

## 4.2 在 BoltDB 二进制文件中搜索明文

我们刚才写入的字符串是 `from raft storage`。如果 Vault 没有加密，理论上这个字符串应该能在 `vault.db` 里被搜到：

```bash
# 用 strings 提取所有可打印字符串，然后搜索我们写入的明文
strings /opt/vault/data/raft/vault.db | grep -i "from raft storage" || echo "❌ 找不到明文 — Barrier 加密生效！"
strings /opt/vault/data/raft/vault.db | grep -i "hello" || echo "❌ 连键名都搜不到"
```

预期结果是：**两条 `grep` 都返回找不到**，因为：

1. 数据值经过 Barrier 用 Encryption Key 加密
2. 元数据键名也在 Vault 内部经过哈希处理后才落盘

## 4.3 反向验证：先封印再尝试读取

让我们体验一下"封印"的瞬时效果——管理员发现入侵后第一反应就是封印 Vault。

```bash
# 封印 Vault
vault operator seal

# 尝试读取数据
vault kv get secret/hello
```

你会立刻收到 `Vault is sealed` 错误。Vault 进程仍在运行、API 端口仍在监听、Raft 数据库还在磁盘上完好无损——但 Encryption Key 已从内存中销毁，没有任何人（包括 root 用户）能读到任何数据。

## 4.4 再次解封确认数据未损

```bash
vault operator unseal "$UNSEAL_KEY_1"
vault operator unseal "$UNSEAL_KEY_2"
vault operator unseal "$UNSEAL_KEY_3"

vault kv get secret/hello
```

数据完好无损。这就是 **Barrier + Seal/Unseal** 双重设计的精妙之处：

- **Barrier** 保证 **静态数据加密**——盘里全是密文
- **Sealed 状态** 提供 **运行时一键熔断**——发现异常瞬间切断访问

## 关键认知小结

| 现象 | 背后的机制 |
| :--- | :--- |
| `vault.db` 里搜不到明文 | Barrier 用 AES-GCM-256 加密了所有用户数据 |
| 封印后 API 立即拒绝访问 | Encryption Key 从内存清除，但磁盘数据完整 |
| 重新解封后数据完好 | Shamir Key 重组 → 解密 Root Key → 解密 Encryption Key → 解密数据 |
| 任意 3 份分片即可解封 | Shamir's Secret Sharing 的数学性质 |

至此你已经亲手完成了一个生产风格 Vault 的完整生命周期：**安装 → 配置 → 启动 → 初始化 → 解封 → 写入 → 封印 → 再解封**。后续章节我们会在这个心智模型的基础上，逐步引入认证方法、策略、动态机密、WIF、OIDC Provider 等现代特性。

点击 **Continue** 完成本实验。
