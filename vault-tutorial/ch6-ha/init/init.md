# 实验说明

本实验配套 [6.5 节正文](/ch6-ha)：学员此时已经在概念层理解了"活跃节点抢锁、待命节点转发或重定向"这一 HA 基本运作模型，本实验把其中四组概念做成可在终端里直接观察到的现象：

1. 用 `sys/leader` API 区分 active / standby；
2. 默认情况下向 standby 发请求被**透明转发**，客户端拿到的就是 200 响应；
3. 加上 `X-Vault-No-Request-Forwarding: 1` 后，standby 改以 `307` 重定向回 active 节点的 `api_addr`；
4. 终止当前 leader 进程后，Raft 重新选举出新的 active，先前的两条路径将随新 leader 自动迁移。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成——3 个 Vault 进程通过 `127.0.0.1` 上的不同端口隔离（API 8200/8210/8220、cluster 8201/8211/8221）。每个节点的 `api_addr` 都配置为 **"指向该节点自己"**，这正是 6.5 节"4.1 客户端可直接访问每台 Vault"中描述的标准部署形态。

实验开始时，环境已完成下列准备：

- 已安装 `vault`（1.19.2）与 `jq`、`curl`；
- 已为 3 个节点预置完整的 `vault.hcl`：
  - `/root/vault-1.hcl`：node-1，API 8200，cluster 8201，作为 bootstrap 节点（无 `retry_join`）；
  - `/root/vault-2.hcl`：node-2，API 8210，cluster 8211，通过 `retry_join` 指向 node-1；
  - `/root/vault-3.hcl`：node-3，API 8220，cluster 8221，通过 `retry_join` 指向 node-1；
- 已为每个节点预创建独立的 raft 数据目录 `/opt/vault/data-{1,2,3}`；
- 已把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/`，登录 shell 自动加载；
- 已生成便捷启动脚本 `/root/start-node.sh`，用法 `./start-node.sh <1|2|3>`，在后台启动指定节点并把日志写到 `/var/log/vault-N.log`。

> 本实验全程使用明文 HTTP（`tls_disable = true`），目的是让 `curl -i` 输出干净易读、便于直接观察 `307` 状态行与 `Location` 头。生产环境请按 6.2 节的基线启用 TLS。
