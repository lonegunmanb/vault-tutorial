# 第一步：阅读最小可启动的 vault.hcl

先看一下预置的配置文件。

```bash
cat /root/vault.hcl
```

请逐项对照 6.1 节的讲解，识别下列结构：

| 配置元素 | 类型 | 在本实验中的作用 |
| :--- | :--- | :--- |
| `ui = true` | 顶层标量 | 启用内置 Web UI |
| `disable_mlock = true` | 顶层标量 | 使用 raft 存储时**必须**显式给出，且建议为 `true` |
| `cluster_name` | 顶层标量 | 给本集群一个人类可读的名字 |
| `log_level = "info"` | 顶层标量 | 日志详尽程度（步骤 3 会通过 SIGHUP 改它） |
| `pid_file` | 顶层标量 | 把 Vault 进程 PID 写入文件，步骤 3 用它发送 SIGHUP |
| `api_addr` / `cluster_addr` | 顶层标量 | 节点间互相通告的两个地址 |
| `storage "raft" { ... }` | 命名块 | 必填；声明数据落到哪里 |
| `listener "tcp" { ... }` | 命名块 | 必填；声明 API 在哪个地址监听 |
| `default_lease_ttl` / `max_lease_ttl` | 顶层标量 | 全局租约默认值与上限，覆盖默认 768h |

确认数据目录存在且为空：

```bash
ls -la /opt/vault/data
```

确认 Vault 命令可用，但服务**还没启动**：

```bash
vault version
vault status || true
```

`vault status` 现在会报错连接被拒绝，这是预期的：进程尚未启动。下一步会亲手启动它。
