# 第二步：观察加密密钥轮换

现在观察 Vault 的 underlying encryption key。先查看当前 key term、安装时间和加密次数。

```bash
source /root/operator-lab/single-env.sh

vault operator key-status
```

手动轮换 encryption key，然后再次查看 key status。

```bash
vault operator rotate
vault operator key-status
```

你应看到 `Key Term` 增加。这里轮换的是保护存储数据的 encryption key，不是 unseal keys。

也可以读取自动轮换策略配置，观察 Vault 允许通过系统路径配置轮换间隔或最大加密操作次数。

```bash
vault read sys/rotate/config
```

观察要点：`rotate` 是在线操作；这里轮换的是保护存储数据的 encryption key，不是初始化时生成的 unseal keys。