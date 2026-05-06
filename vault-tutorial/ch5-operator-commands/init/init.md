# 实验：operator 初始化、密钥轮换与 Raft 集群观测

本实验围绕 `vault operator` 命令组展开。你将使用两个环境：一个本地文件存储 Vault，用来观察初始化、加密密钥轮换和 root token 应急生成；一个三节点 Integrated Storage Raft 小集群，用来观察 peer、HA 成员、Autopilot 和 snapshot。

实验已经为你准备好配置文件和启动脚本，但不会自动初始化 Vault。这样做的目的，是让你亲自经历从“空存储”到“可服务 Vault”的关键状态转换。

主要文件如下：

- `single.hcl`：文件存储 Vault 配置，监听 `127.0.0.1:8300`。
- `start-single.sh`：启动一个未初始化的文件存储 Vault。
- `activate-single.sh`：在初始化之后激活本地 Vault，并写入后续步骤所需的环境变量文件。
- `raft1.hcl`、`raft2.hcl`、`raft3.hcl`：三节点 Raft 配置。
- `start-raft-cluster.sh`：启动并初始化一个三节点 Raft 小集群。
- `migrate-file-to-raft.hcl`：离线存储迁移配置示例。

进入实验目录：

```bash
cd /root/operator-lab
```

完成所有步骤后，可运行以下命令清理本实验启动的 Vault 进程：

```bash
./stop-lab.sh
```