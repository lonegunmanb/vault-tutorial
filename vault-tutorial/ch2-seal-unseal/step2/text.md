# 第二步：Rotate —— DEK 在线轮转

`vault operator rotate` 作用在三层密钥结构的**最内层**——DEK（数据加密密钥）。它会生成一个**新的 DEK**，从此以后所有新写入的数据都用新 DEK 加密。**老 DEK 不会被销毁**——它继续保留在 keyring 里，用于解密之前已经写入的密文。

## 2.1 查看当前 DEK 状态

```bash
vault read sys/key-status
```

输出：

```
Key            Value
---            -----
encryptions    n/a
install_time   2026-xx-xx...
term           1                ← 当前 DEK 版本号
```

`term=1` 表示这是 Vault 初始化时生成的第一个 DEK。环境已经预先用 term=1 写入了一条机密 `secret/before-rotate`：

```bash
vault kv get secret/before-rotate
```

```
====== Data ======
Key       Value
---       -----
message   this-was-encrypted-with-DEK-term-1
```

## 2.2 执行 Rotate

```bash
vault operator rotate
```

```
Success! Rotated key

Key Term        2                ← 版本号 +1
Install Time    2026-xx-xx...
```

再看一次：

```bash
vault read sys/key-status
```

```
term           2                ← 升级到 2
```

**这条命令没有要求任何分片授权**——已解封状态下的管理员（持有 `sys/rotate` 权限的 Token）即可执行。

## 2.3 写一条新机密：用 term=2 加密

```bash
vault kv put secret/after-rotate \
  message="this-was-encrypted-with-DEK-term-2"

vault kv get secret/after-rotate
```

## 2.4 验证 keyring 兼容：老数据仍然可读

```bash
vault kv get secret/before-rotate
```

```
====== Data ======
Key       Value
---       -----
message   this-was-encrypted-with-DEK-term-1
```

**老数据原封不动地读了出来**——Vault 内部维护的"keyring"自动用 term=1 的老 DEK 解密这条记录。这是 rotate 设计的核心特性：**轮转一个新的加密密钥不需要重新加密历史数据**，避免了一次性扫描全库的巨大 I/O 开销。

## 2.5 直接看一眼磁盘上的密文（可选）

如果你想确认两条机密在磁盘上确实是**用不同 DEK 加密的不同密文**：

```bash
ls /opt/vault/data/logical/ 2>/dev/null | head -5
```

由于路径会被混淆，简单的 `grep` 找不到具体记录——但你可以确信：磁盘上每个加密单元的 header 都标注了"我是用哪个 term 的 DEK 加密的"，Vault 启动后用 keyring 中对应的 DEK 解密。

## 2.6 Rotate 的关键事实回顾

| 维度 | 表现 |
| :--- | :--- |
| 影响层级 | DEK |
| 是否需要分片授权 | ❌ 不需要 |
| 老数据是否需要重新加密 | ❌ 不需要（keyring 兼容） |
| Unseal Key 是否变化 | ❌ 完全不变 |
| Root Token 是否受影响 | ❌ 不变 |
| 典型生产频率 | 高频（如每月一次） |
| 命令背后的 API | [`POST /sys/rotate`](https://developer.hashicorp.com/vault/api-docs/system/rotate) |

记住："**rotate 是无痛的、日常的、不需要协调多人的**"。

完成后点击 **Continue** 进入第三步——一个完全不同的命令：rekey。
