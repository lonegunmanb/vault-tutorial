# 第四步：写入 KV 数据并保存 raft snapshot

[6.4 节 §12](/ch6-integrated-storage) 强调：离线 raft snapshot 是 Vault 生产部署的最低标配，**snapshot 和 Recovery Mode 不是替代关系**——前者用于"数据回滚"，后者用于"进程根本无法启动"。本步在已经稳定运行的 3 节点集群上写入一些 KV 业务数据，再用 `vault operator raft snapshot save` 拍下一份离线快照——这份快照将在 Step 6 用于演示数据回滚。

## 4.1 启用 KV v2 引擎并写入示例数据

```bash
vault secrets enable -path=secret kv-v2
```

输出 `Success! Enabled the kv-v2 secrets engine at: secret/`。

写入两条测试数据：

```bash
vault kv put secret/app/db username=alice password=before-snapshot
vault kv put secret/app/api token=token-before-snapshot region=us-east-1
```

确认数据已写入：

```bash
vault kv get secret/app/db
vault kv get secret/app/api
```

两条命令都应返回各自的 key/value 字段。

## 4.2 保存 raft snapshot

```bash
vault operator raft snapshot save /root/raft-good.snap
ls -la /root/raft-good.snap
```

文件大小通常在几十 KB 到几百 KB 之间——Vault 把整个 raft 状态机（包括所有 KV 数据、auth method、policy 配置等）压缩封装在这一份快照里。

## 4.3 检查 snapshot 文件结构

[6.4 节 §12](/ch6-integrated-storage) 提到 `snapshot inspect` 可以打印快照内 key 数量与占用空间：

```bash
vault operator raft snapshot inspect /root/raft-good.snap
```

输出顶部会显示快照的 `ID`、`Size`、`Index`、`Term` 与 `Version`；下方表格按 `Key Name` 汇总每类底层存储前缀的 `Count` 与 `Size`，末尾还有 `Total Size`。这可用于判断快照是否能被正常解析、与预期数据规模是否相符。

## 4.4 故意写入"快照之后"的数据，标记两个时间点的差异

为了让 Step 6 的 snapshot restore 效果可观察，再写入一条快照之后才出现的数据：

```bash
vault kv put secret/app/db username=alice password=AFTER-snapshot-MUST-DISAPPEAR
vault kv get secret/app/db
```

最后一条命令的输出应当显示 `password = AFTER-snapshot-MUST-DISAPPEAR`。

> **关键观察点**：本实验的设计意图是——Step 6 完成 snapshot restore 后，`secret/app/db` 应当回到 `password = before-snapshot`，"AFTER-snapshot" 这条修改会消失。这正是离线快照"数据回滚"语义的具象化。

## 4.5 这一步的核心闭环

KV 引擎已启用并写入业务数据；一份离线 raft snapshot 已保存到 `/root/raft-good.snap` 并通过 `inspect` 验证文件结构；同时故意写入了"快照之后"的数据，作为 Step 6 数据回滚效果的对比基准。下一步开始破坏性操作：复现 quorum 永久丢失场景。
