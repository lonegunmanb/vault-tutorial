# 实验完成

你已经完成了 `vault operator` 命令组中最重要的运维路径：

- 用 `operator init` 初始化空存储，并理解 key shares 与 threshold。
- 用 `operator key-status` 与 `operator rotate` 区分 encryption key 轮换和 unseal key。
- 用 `operator generate-root` 体验 quorum 参与的应急 root token 生成流程。
- 用 `operator raft list-peers`、`operator members`、`operator raft autopilot state` 与 snapshot 命令观察 Raft 集群。
- 用 `operator diagnose`、`operator usage` 与 `operator migrate` 配置理解诊断、报告和离线迁移边界。

清理本实验启动的 Vault 进程：

```bash
cd /root/operator-lab
./stop-lab.sh
```

继续学习时，可以回到正文，把每个命令放回五条主线中复盘：启动与封印状态、密钥材料治理、Raft 与 HA 集群、迁移与诊断、治理报告。